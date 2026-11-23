public import AppKit
import CmuxNextActions
public import CmuxNextSettings
import os

/// App menu > Customizations: every Experiments and Labs switch as a checkmark row, two clicks from
/// anywhere (Leo 2026-11-22, ask-931361017e). The rows come from `SettingsSchema.quickToggleGroups`
/// and are rebuilt each time the menu opens, so the checkmarks show the value in effect and a new
/// schema row appears with no edit here. A click flips the switch through
/// `SettingsController.flip` (the guarded `setSetting`); a managed row is disabled. Under the
/// groups, Turn Off All Experiments and Labs puts every opt-in switch back to its default
/// (`SettingsController.turnAllOff`), native, so it works when a customization broke the Settings
/// page (Leo, 2026-11-23, c-dc594b45e0: "have good recovery options"); it is disabled while none is
/// on. The last row runs `openAll` (Settings > Customize).
@MainActor
public final class CustomizationsMenu: NSObject, NSMenuDelegate {
    private let settings: @MainActor () -> SettingsController?
    private let openAll: @MainActor () -> Void
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "menu.customizations")

    private init(settings: @escaping @MainActor () -> SettingsController?, openAll: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.openAll = openAll
    }

    /// The submenu's item; it keeps its delegate alive (`representedObject`: `NSMenu.delegate` is weak).
    public static func item(settings: @escaping @MainActor () -> SettingsController?,
                            openAll: @escaping @MainActor () -> Void) -> NSMenuItem {
        let owner = CustomizationsMenu(settings: settings, openAll: openAll)
        let item = NSMenuItem(title: SettingsWindowStrings.customizationsMenu, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: SettingsWindowStrings.customizationsMenu)
        menu.autoenablesItems = false
        menu.delegate = owner
        item.submenu = menu
        item.representedObject = owner
        return item
    }

    /// `items` with `item` after the last one titled the first of `titles` found, else at the end.
    public static func inserting(_ item: NSMenuItem, into items: [NSMenuItem], after titles: [String?]) -> [NSMenuItem] {
        let index = titles.compactMap { title in items.lastIndex(where: { $0.title == title }) }.first
        var items = items
        items.insert(item, at: index.map { $0 + 1 } ?? items.count)
        return items
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = settings()
        let groups = SettingsSchema.quickToggleGroups(developerTools: DevTools.isEnabled)
        for group in groups {
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
        let off = NSMenuItem(title: SettingsWindowStrings.turnAllOff, action: #selector(turnAllOff(_:)), keyEquivalent: "")
        off.target = self
        off.isEnabled = settings.map { !$0.turnOffTargets(in: groups).isEmpty } ?? false
        menu.addItem(off)
        let all = NSMenuItem(title: SettingsWindowStrings.allCustomizations, action: #selector(openAllClicked(_:)), keyEquivalent: "")
        all.target = self
        menu.addItem(all)
    }

    @objc private func flip(_ sender: NSMenuItem) {
        guard let settings = settings(), let id = sender.representedObject as? String,
              let descriptor = SettingsSchema.descriptor(for: id.split(separator: ".").map(String.init)) else { return }
        Task {
            do {
                try await settings.flip(descriptor)
            } catch {
                Self.logger.error("customizations menu \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    @objc private func turnAllOff(_ sender: NSMenuItem) {
        guard let settings = settings() else { return }
        let groups = SettingsSchema.quickToggleGroups(developerTools: DevTools.isEnabled)
        Task {
            do {
                try await settings.turnAllOff(in: groups)
            } catch {
                Self.logger.error("customizations menu turn all off failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    @objc private func openAllClicked(_ sender: NSMenuItem) { openAll() }
}
