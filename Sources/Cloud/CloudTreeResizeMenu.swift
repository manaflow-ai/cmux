import CmuxCloud
import AppKit
import Foundation

/// Builds the provider-backed grow-only resource resize submenu for a Cloud machine row.
struct CloudTreeResizeMenu {
    @MainActor
    static func item(machine: MachineSnapshot, id: String, action: MachineRowActions) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if !action.resizeDiskOptionsGiB.isEmpty {
            let diskMenu = NSMenu(); diskMenu.autoenablesItems = false
            let currentDiskMb = machine.resourceReservation?.diskMb ?? machine.stats?.diskTotalMb
            for gib in action.resizeDiskOptionsGiB {
                let title = String(format: String(localized: "machines.menu.resizeToGiB", defaultValue: "Increase to %d GiB"), gib)
                let entry = CloudTreeMenuItem(title: title) { action.resizeDisk(id, gib) }
                let computeFits = machine.usesResourcePool || Self.poolFits(
                    machine: machine,
                    action: action,
                    targetCPUs: currentCPUs,
                    targetMemoryMb: currentMemoryMb
                )
                if gib > action.resizeDiskMaximumGiB ||
                    (currentDiskMb.map { $0 >= gib * 1024 } ?? false) || !computeFits {
                    entry.isEnabled = false
                }
                diskMenu.addItem(entry)
            }
            submenu.addItem(Self.group(title: String(localized: "machines.menu.increaseDisk", defaultValue: "Increase Disk"), menu: diskMenu))
        }

        if !action.resizeCPUOptions.isEmpty {
            let cpuMenu = NSMenu(); cpuMenu.autoenablesItems = false
            let currentCPUs = machine.resourceReservation?.vcpus ?? machine.stats?.cpus
            for cpu in action.resizeCPUOptions {
                let title = String(format: String(localized: "machines.menu.resizeToVCPUs", defaultValue: "Increase to %d vCPUs"), cpu)
                let entry = CloudTreeMenuItem(title: title) { action.resizeCPU(id, cpu) }
                let exceedsPool = !Self.poolFits(
                    machine: machine,
                    action: action,
                    targetCPUs: cpu,
                    targetMemoryMb: currentMemoryMb
                )
                if cpu > action.resizeCPUMaximum ||
                    (currentCPUs.map { $0 >= cpu } ?? false) || exceedsPool {
                    entry.isEnabled = false
                }
                cpuMenu.addItem(entry)
            }
            submenu.addItem(Self.group(title: String(localized: "machines.menu.increaseCPU", defaultValue: "Increase CPU"), menu: cpuMenu))
        }

        if !action.resizeMemoryOptionsGiB.isEmpty {
            let memoryMenu = NSMenu(); memoryMenu.autoenablesItems = false
            let currentMemoryMb = machine.resourceReservation?.memoryMb ?? machine.stats?.memoryTotalMb
            for gib in action.resizeMemoryOptionsGiB {
                let title = String(format: String(localized: "machines.menu.resizeToGiB", defaultValue: "Increase to %d GiB"), gib)
                let entry = CloudTreeMenuItem(title: title) { action.resizeMemory(id, gib) }
                let exceedsPool = !Self.poolFits(
                    machine: machine,
                    action: action,
                    targetCPUs: currentCPUs,
                    targetMemoryMb: gib * 1024
                )
                if gib > action.resizeMemoryMaximumGiB ||
                    (currentMemoryMb.map { $0 >= gib * 1024 } ?? false) || exceedsPool {
                    entry.isEnabled = false
                }
                memoryMenu.addItem(entry)
            }
            submenu.addItem(Self.group(title: String(localized: "machines.menu.increaseMemory", defaultValue: "Increase Memory"), menu: memoryMenu))
        }

        let root = NSMenuItem(
            title: String(localized: "cloud.operation.kind.resize", defaultValue: "Resize machine"),
            action: nil,
            keyEquivalent: ""
        )
        root.submenu = submenu
        return root
    }

    private static func group(title: String, menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// Tests the complete target shape against the shared pool. Active machines
    /// already appear in `used*`, so their current reservation is removed
    /// before evaluating the target. Paused machines are evaluated as a new
    /// allocation because resizing wakes them. Unknown compute shape fails
    /// closed when a pool is present; disk-only active resizes skip admission.
    private static func poolFits(
        machine: MachineSnapshot,
        action: MachineRowActions,
        targetCPUs: Int?,
        targetMemoryMb: Int?
    ) -> Bool {
        guard let pool = action.resizeResourcePool else { return true }
        guard let targetCPUs, let targetMemoryMb else { return false }

        var usedCPUs = pool.usedVcpus
        var usedMemoryMb = pool.usedMemoryMb
        if machine.usesResourcePool {
            let currentCPUs = machine.resourceReservation?.vcpus ?? machine.stats?.cpus
            let currentMemoryMb = machine.resourceReservation?.memoryMb ?? machine.stats?.memoryTotalMb
            guard let currentCPUs, let currentMemoryMb else { return false }
            usedCPUs = max(0, usedCPUs - currentCPUs)
            usedMemoryMb = max(0, usedMemoryMb - currentMemoryMb)
        }
        return targetCPUs <= max(0, pool.poolVcpus - usedCPUs) &&
            targetMemoryMb <= max(0, pool.poolMemoryMb - usedMemoryMb)
    }
}
