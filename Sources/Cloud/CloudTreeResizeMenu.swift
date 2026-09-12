import AppKit
import Foundation

/// Builds the provider-backed disk resize submenu for a Cloud machine row.
struct CloudTreeResizeMenu {
    @MainActor
    static func item(machine: MachineSnapshot, id: String, action: MachineRowActions) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for gib in [64, 128, 256] {
            let title = String(format: String(localized: "machines.menu.increaseDiskTo", defaultValue: "Increase to %d GiB"), gib)
            let resize = CloudTreeMenuItem(title: title) { action.resizeDisk(id, gib) }
            if let current = machine.stats?.diskTotalMb, current >= gib * 1024 { resize.isEnabled = false }
            submenu.addItem(resize)
        }
        let cpuMenu = NSMenu(); cpuMenu.autoenablesItems = false
        for cpu in [2, 4, 8, 16, 32] {
            let entry = CloudTreeMenuItem(title: String(format: String(localized: "machines.menu.increaseDiskTo", defaultValue: "Increase to %d GiB"), cpu)) { action.resizeCPU(id, cpu) }
            if let current = machine.stats?.cpus, current >= cpu { entry.isEnabled = false }
            cpuMenu.addItem(entry)
        }
        let cpuRoot = NSMenuItem(title: String(localized: "machines.menu.increaseDisk", defaultValue: "Increase Disk"), action: nil, keyEquivalent: "")
        cpuRoot.submenu = cpuMenu
        submenu.insertItem(cpuRoot, at: 0)
        let memoryMenu = NSMenu(); memoryMenu.autoenablesItems = false
        for gib in [16, 24, 32, 64] {
            let entry = CloudTreeMenuItem(title: String(format: String(localized: "machines.menu.increaseDiskTo", defaultValue: "Increase to %d GiB"), gib)) { action.resizeMemory(id, gib) }
            if let current = machine.stats?.memoryTotalMb, current >= gib * 1024 { entry.isEnabled = false }
            memoryMenu.addItem(entry)
        }
        let memoryRoot = NSMenuItem(title: String(localized: "machines.menu.increaseDisk", defaultValue: "Increase Disk"), action: nil, keyEquivalent: "")
        memoryRoot.submenu = memoryMenu
        submenu.insertItem(memoryRoot, at: 0)
        let root = NSMenuItem(
            title: String(localized: "machines.menu.increaseDisk", defaultValue: "Increase Disk"),
            action: nil,
            keyEquivalent: ""
        )
        root.submenu = submenu
        return root
    }
}
