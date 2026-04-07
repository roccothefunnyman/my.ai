<#
.SYNOPSIS
    Discovers Azure VMs that do not have Reserved Instance coverage.

.DESCRIPTION
    Scans all accessible subscriptions for running VMs, compares them against
    existing reservation orders, and outputs a CSV report of VMs that are not
    covered by a reserved instance. Designed to run in Azure Cloud Shell.

.NOTES
    Run this in Azure Cloud Shell (PowerShell). The output CSV is saved to
    your Cloud Shell home directory (~/) so it persists across sessions.

    The matching logic compares VM size and location against existing
    reservation SKUs. It does quantity-based matching: if you have 3 RIs
    for Standard_D4s_v3 in eastus but 5 VMs of that size there, the 2
    excess VMs will appear in the report.
#>

param(
    [string]$OutputPath = "$HOME/ri-gap-report.csv"
)

$ErrorActionPreference = "Stop"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Azure Reserved Instance Gap Analysis" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ---------------------------------------------------------------
# Step 1: Get all existing reservations
# ---------------------------------------------------------------
Write-Host "Fetching existing reservation orders..." -ForegroundColor Yellow

$reservations = @()
try {
    $reservationOrders = Get-AzReservationOrder -ErrorAction SilentlyContinue
    foreach ($order in $reservationOrders) {
        $orderReservations = Get-AzReservation -ReservationOrderId $order.Name -ErrorAction SilentlyContinue
        foreach ($res in $orderReservations) {
            if ($res.ProvisioningState -eq "Succeeded" -and
                $res.DisplayProvisioningState -ne "Expired" -and
                $res.DisplayProvisioningState -ne "Cancelled") {
                $reservations += [PSCustomObject]@{
                    ReservationId   = $res.Name
                    SkuName         = $res.Sku.Name
                    Location        = $res.Location
                    Quantity        = $res.Quantity
                    Term            = $res.Term
                    ExpiryDate      = $res.ExpiryDate
                    Scope           = $res.AppliedScopeType
                }
            }
        }
    }
}
catch {
    Write-Host "Note: Could not retrieve reservations. You may not have Reservation Reader role." -ForegroundColor DarkYellow
    Write-Host "Proceeding with the assumption that no reservations exist.`n" -ForegroundColor DarkYellow
}

Write-Host "Found $($reservations.Count) active reservation(s).`n" -ForegroundColor Green

# Build a lookup of reserved capacity: key = "vmSize|location", value = total quantity
$reservedCapacity = @{}
foreach ($res in $reservations) {
    $key = "$($res.SkuName)|$($res.Location)".ToLower()
    if ($reservedCapacity.ContainsKey($key)) {
        $reservedCapacity[$key] += $res.Quantity
    }
    else {
        $reservedCapacity[$key] = $res.Quantity
    }
}

# ---------------------------------------------------------------
# Step 2: Get all running VMs across all subscriptions
# ---------------------------------------------------------------
Write-Host "Scanning subscriptions for running VMs..." -ForegroundColor Yellow

$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
$allVMs = @()

foreach ($sub in $subscriptions) {
    Write-Host "  Scanning: $($sub.Name)" -ForegroundColor Gray
    Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null

    $vms = Get-AzVM -Status -ErrorAction SilentlyContinue
    foreach ($vm in $vms) {
        $powerState = ($vm.Statuses | Where-Object { $_.Code -like "PowerState/*" }).Code
        if ($powerState -eq "PowerState/running") {
            $allVMs += [PSCustomObject]@{
                SubscriptionName = $sub.Name
                SubscriptionId   = $sub.Id
                ResourceGroup    = $vm.ResourceGroupName
                VMName           = $vm.Name
                VMSize           = $vm.HardwareProfile.VmSize
                Location         = $vm.Location
                OsType           = $vm.StorageProfile.OsDisk.OsType
                PowerState       = "Running"
            }
        }
    }
}

Write-Host "`nFound $($allVMs.Count) running VM(s) across $($subscriptions.Count) subscription(s).`n" -ForegroundColor Green

# ---------------------------------------------------------------
# Step 3: Match VMs against reserved capacity
# ---------------------------------------------------------------
Write-Host "Matching VMs against reserved capacity..." -ForegroundColor Yellow

# Track how much reserved capacity has been consumed
$consumedCapacity = @{}
$uncoveredVMs = @()

# Sort VMs for deterministic matching
$sortedVMs = $allVMs | Sort-Object Location, VMSize, VMName

foreach ($vm in $sortedVMs) {
    $key = "$($vm.VMSize)|$($vm.Location)".ToLower()

    $totalReserved = if ($reservedCapacity.ContainsKey($key)) { $reservedCapacity[$key] } else { 0 }
    $consumed = if ($consumedCapacity.ContainsKey($key)) { $consumedCapacity[$key] } else { 0 }

    if ($consumed -lt $totalReserved) {
        # This VM is covered by an existing reservation
        if ($consumedCapacity.ContainsKey($key)) {
            $consumedCapacity[$key]++
        }
        else {
            $consumedCapacity[$key] = 1
        }
    }
    else {
        # This VM has no RI coverage
        $uncoveredVMs += [PSCustomObject]@{
            SubscriptionName = $vm.SubscriptionName
            SubscriptionId   = $vm.SubscriptionId
            ResourceGroup    = $vm.ResourceGroup
            VMName           = $vm.VMName
            VMSize           = $vm.VMSize
            Location         = $vm.Location
            OsType           = $vm.OsType
        }
    }
}

# ---------------------------------------------------------------
# Step 4: Build purchase recommendation summary
# ---------------------------------------------------------------
$purchaseSummary = $uncoveredVMs |
    Group-Object VMSize, Location |
    ForEach-Object {
        $parts = $_.Name -split ", "
        [PSCustomObject]@{
            VMSize   = $parts[0]
            Location = $parts[1]
            Quantity = $_.Count
        }
    } |
    Sort-Object Location, VMSize

# ---------------------------------------------------------------
# Step 5: Output results
# ---------------------------------------------------------------
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Results" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "Total running VMs:          $($allVMs.Count)" -ForegroundColor White
Write-Host "VMs with RI coverage:       $($allVMs.Count - $uncoveredVMs.Count)" -ForegroundColor Green
Write-Host "VMs WITHOUT RI coverage:    $($uncoveredVMs.Count)" -ForegroundColor Red
Write-Host ""

if ($purchaseSummary.Count -gt 0) {
    Write-Host "Purchase Recommendation Summary:" -ForegroundColor Yellow
    Write-Host "--------------------------------" -ForegroundColor Yellow
    $purchaseSummary | Format-Table -AutoSize
}
else {
    Write-Host "All running VMs are covered by existing reservations." -ForegroundColor Green
}

# Export detailed report
$uncoveredVMs | Export-Csv -Path $OutputPath -NoTypeInformation -Force
Write-Host "Detailed report saved to: $OutputPath" -ForegroundColor Green

# Also export the purchase summary
$summaryPath = $OutputPath -replace '\.csv$', '-summary.csv'
$purchaseSummary | Export-Csv -Path $summaryPath -NoTypeInformation -Force
Write-Host "Purchase summary saved to: $summaryPath`n" -ForegroundColor Green

Write-Host "Next step: Review the report, then run Purchase-ReservedInstances.ps1" -ForegroundColor Cyan
Write-Host "to purchase the recommended reservations.`n" -ForegroundColor Cyan
