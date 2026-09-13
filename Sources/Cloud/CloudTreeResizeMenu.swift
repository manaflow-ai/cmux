import AppKit
import Foundation

/// Builds the provider-backed grow-only resource resize submenu for a Cloud machine row.
struct CloudTreeResizeMenu {
    @MainActor
    static func item(machine: MachineSnapshot, id: String, action: MachineRowActions) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let diskMenu = NSMenu(); diskMenu.autoenablesItems = false
        for gib in [64, 128, 256] {
            let title = String(format: String(localized: "machines.menu.resizeToGiB", defaultValue: "Increase to %d GiB"), gib)
            let entry = CloudTreeMenuItem(title: title) { action.resizeDisk(id, gib) }
            if let current = machine.stats?.diskTotalMb, current >= gib * 1024 { entry.isEnabled = false }
            diskMenu.addItem(entry)
        }
        submenu.addItem(Self.group(title: String(localized: "machines.menu.increaseDisk", defaultValue: "Increase Disk"), menu: diskMenu))

        let cpuMenu = NSMenu(); cpuMenu.autoenablesItems = false
        let cpuTargets = action.resizeCPUOptions.isEmpty ? [2, 4, 8, 16, 32] : action.resizeCPUOptions
        for cpu in cpuTargets {
            let title = String(format: String(localized: "machines.menu.resizeToVCPUs", defaultValue: "Increase to %d vCPUs"), cpu)
            let entry = CloudTreeMenuItem(title: title) { action.resizeCPU(id, cpu) }
            if let current = machine.stats?.cpus, current >= cpu { entry.isEnabled = false }
            cpuMenu.addItem(entry)
        }
        submenu.addItem(Self.group(title: String(localized: "machines.menu.increaseCPU", defaultValue: "Increase CPU"), menu: cpuMenu))

        let memoryMenu = NSMenu(); memoryMenu.autoenablesItems = false
        let memoryTargets = action.resizeMemoryOptionsGiB.isEmpty ? [8, 16, 24, 32, 64] : action.resizeMemoryOptionsGiB
        for gib in memoryTargets {
            let title = String(format: String(localized: "machines.menu.resizeToGiB", defaultValue: "Increase to %d GiB"), gib)
            let entry = CloudTreeMenuItem(title: title) { action.resizeMemory(id, gib) }
            if let current = machine.stats?.memoryTotalMb, current >= gib * 1024 { entry.isEnabled = false }
            memoryMenu.addItem(entry)
        }
        submenu.addItem(Self.group(title: String(localized: "machines.menu.increaseMemory", defaultValue: "Increase Memory"), menu: memoryMenu))

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
