import AppKit
import CmuxNextActions
import CmuxNextSettings
import os

/// App menu > Customizations: every Experiments and Labs switch as a checkmark row, two clicks from
/// anywhere (Leo 2026-11-22, ask-931361017e). The rows come from `SettingsSchema.quickToggleGroups`
/// and are rebuilt each time the menu opens, so the checkmarks show the value in effect and a new
/// schema row appears with no edit here. A click flips the switch through
/// `SettingsController.flip` (the guarded `setSetting`); a managed row is disabled. The last row
/// opens Settings > Customize.
@MainActor
final class CustomizationsMenu: NSObject, NSMenuDelegate {
    private weak var services: AppServices?
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "menu.customizations")

    private init(services: AppServices) {
        self.services = services
    }

    /// The submenu's item; it keeps its delegate alive (`representedObject`, since `NSMenu.delegate` is weak).
    static func item(services: AppServices) -> NSMenuItem {
        let owner = CustomizationsMenu(services: services)
        let item = NSMenuItem(title: Strings.menuCustomizations, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: Strings.menuCustomizations)
        menu.autoenablesItems = false
        menu.delegate = owner
        item.submenu = menu
        item.representedObject = owner
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = services?.settings
        for group in SettingsSchema.quickToggleGroups(developerTools: DevTools.isEnabled) {
            menu.addItem(.sectionHeader(title: group.title))
            for descriptor in group.rows {
                let row = NSMenuItem(title: descriptor.title, action: #selector(flip(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = descriptor.id
                row.toolTip = descriptor.help
                row.state = settings?.isOn(descriptor) == true ? .on : .off
                row.isEnabled = settings.map { !$0.isLocked(descriptor) } ?? false
                menu.addItem(row)
            }
        }
        menu.addItem(.separator())
        let all = NSMenuItem(title: Strings.menuAllCustomizations, action: #selector(openAll(_:)), keyEquivalent: "")
        all.target = self
        menu.addItem(all)
    }

    @objc private func flip(_ sender: NSMenuItem) {
        guard let settings = services?.settings, let id = sender.representedObject as? String,
              let descriptor = SettingsSchema.descriptor(for: id.split(separator: ".").map(String.init)) else { return }
        Task {
            do {
                try await settings.flip(descriptor)
            } catch {
                Self.logger.error("customizations menu \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Settings > Customize; a build whose page lacks that category opens the default one (`categoryOf`).
    @objc private func openAll(_ sender: NSMenuItem) {
        do {
            try services?.settingsWindow.show(section: nil, route: "#/settings/customize")
        } catch {
            Self.logger.error("customizations menu: Settings did not open: \(String(describing: error), privacy: .public)")
        }
    }
}
