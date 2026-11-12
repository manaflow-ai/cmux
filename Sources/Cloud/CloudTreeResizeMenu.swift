import CmuxCloud
import CmuxCloudResizeCore
import AppKit
import Foundation

/// Builds the provider-backed grow-only resource resize submenu for a Cloud machine row.
struct CloudTreeResizeMenu {
    @MainActor
    static func item(machine: MachineSnapshot, id: String, action: MachineRowActions) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let currentCPUs = machine.resourceReservation?.vcpus ?? machine.stats?.cpus
        let currentMemoryMb = machine.resourceReservation?.memoryMb ?? machine.stats?.memoryTotalMb
        let currentDiskMb = machine.resourceReservation?.diskMb ?? machine.stats?.diskTotalMb
        let currentShape = CloudVMResizeShape(vcpus: currentCPUs, memoryMb: currentMemoryMb, diskMb: currentDiskMb)
        let poolClaim = machine.resourcePoolClaim ?? machine.resourceReservation
        let poolClaimShape = poolClaim.map { CloudVMResizeShape(vcpus: $0.vcpus, memoryMb: $0.memoryMb, diskMb: $0.diskMb) }
        let limits = CloudVMResizeLimits(
            maxVcpus: action.resizeCPUMaximum,
            maxMemoryMb: action.resizeMemoryMaximumGiB * 1024,
            maxDiskMb: action.resizeDiskMaximumGiB * 1024,
            resourcePool: action.resizeResourcePool
        )

        if !action.resizeDiskOptionsGiB.isEmpty {
            let diskMenu = NSMenu(); diskMenu.autoenablesItems = false
            for gib in action.resizeDiskOptionsGiB {
                let title = String(format: String(localized: "machines.menu.resizeToGiB", defaultValue: "Increase to %d GiB"), gib)
                let entry = CloudTreeMenuItem(title: title) { action.resizeDisk(id, gib) }
                let failure = CloudVMResizePlanValidator().violation(
                    target: CloudVMResizeShape(diskMb: gib * 1024),
                    current: currentShape,
                    usesResourcePool: machine.usesResourcePool,
                    reservation: poolClaimShape,
                    limits: limits
                )
                entry.isEnabled = failure == nil
                diskMenu.addItem(entry)
            }
            submenu.addItem(Self.group(title: String(localized: "machines.menu.increaseDisk", defaultValue: "Increase Disk"), menu: diskMenu))
        }

        if !action.resizeCPUOptions.isEmpty {
            let cpuMenu = NSMenu(); cpuMenu.autoenablesItems = false
            for cpu in action.resizeCPUOptions {
                let title = String(format: String(localized: "machines.menu.resizeToVCPUs", defaultValue: "Increase to %d vCPUs"), cpu)
                let entry = CloudTreeMenuItem(title: title) { action.resizeCPU(id, cpu) }
                let failure = CloudVMResizePlanValidator().violation(
                    target: CloudVMResizeShape(vcpus: cpu),
                    current: currentShape,
                    usesResourcePool: machine.usesResourcePool,
                    reservation: poolClaimShape,
                    limits: limits
                )
                entry.isEnabled = failure == nil
                cpuMenu.addItem(entry)
            }
            submenu.addItem(Self.group(title: String(localized: "machines.menu.increaseCPU", defaultValue: "Increase CPU"), menu: cpuMenu))
        }

        if !action.resizeMemoryOptionsGiB.isEmpty {
            let memoryMenu = NSMenu(); memoryMenu.autoenablesItems = false
            for gib in action.resizeMemoryOptionsGiB {
                let title = String(format: String(localized: "machines.menu.resizeToGiB", defaultValue: "Increase to %d GiB"), gib)
                let entry = CloudTreeMenuItem(title: title) { action.resizeMemory(id, gib) }
                let failure = CloudVMResizePlanValidator().violation(
                    target: CloudVMResizeShape(memoryMb: gib * 1024),
                    current: currentShape,
                    usesResourcePool: machine.usesResourcePool,
                    reservation: poolClaimShape,
                    limits: limits
                )
                entry.isEnabled = failure == nil
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

}
