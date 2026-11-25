public import AppKit
public import CmuxNextActions
public import CmuxNextSettings
import os

/// App menu > Customizations: every Experiments and Labs switch as a checkmark row, two clicks from
/// anywhere (Leo 2026-11-22, ask-931361017e). The rows come from `SettingsSchema.quickToggleGroups`
/// and are rebuilt each time the menu opens, so the checkmarks show the value in effect and a new
/// schema row appears with no edit here. A click flips the switch through
/// `SettingsController.flip` (the guarded `setSetting`); a managed row is disabled. The last row
/// runs `openAll` (Settings > Customize).
@MainActor
public final class CustomizationsMenu: NSObject, NSMenuDelegate {
    private let registry: ActionRegistry
    private let settings: @MainActor () -> SettingsController?
    private let openAll: @MainActor () -> Void
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "menu.customizations")

    private init(registry: ActionRegistry, settings: @escaping @MainActor () -> SettingsController?, openAll: @escaping @MainActor () -> Void) {
        self.registry = registry
        self.settings = settings
        self.openAll = openAll
    }

    /// The submenu's item; it keeps its delegate alive (`representedObject`: `NSMenu.delegate` is weak).
    public static func item(registry: ActionRegistry, settings: @escaping @MainActor () -> SettingsController?,
                            openAll: @escaping @MainActor () -> Void) -> NSMenuItem {
        let owner = CustomizationsMenu(registry: registry, settings: settings, openAll: openAll)
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
        for group in SettingsSchema.quickToggleGroups(developerTools: DevTools.isEnabled) {
            menu.addItem(.sectionHeader(title: group.title))
            for descriptor in group.rows {
                guard let row = registry.makeArgumentMenuItem(for: "palette.toggleSetting",
                                                               arguments: ["setting": .string(descriptor.id),
                                                                           "on": .bool(!(settings?.isOn(descriptor) ?? false))],
                                                               title: descriptor.title) else { continue }
                row.toolTip = descriptor.help
                row.state = settings?.isOn(descriptor) == true ? .on : .off
                row.isEnabled = settings.map { !$0.isLocked(descriptor) } ?? false
                menu.addItem(row)
            }
        }
        menu.addItem(.separator())
        if let all = registry.makeMenuItem(for: "settings.customizeMenus") {
            all.title = SettingsWindowStrings.allCustomizations
            menu.addItem(all)
        }
    }
}
