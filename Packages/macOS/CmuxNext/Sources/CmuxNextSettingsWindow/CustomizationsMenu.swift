public import AppKit
public import CmuxNextActions
public import CmuxNextSettings

/// App menu > Customizations: every Experiments and Labs switch as a checkmark row, two clicks from
/// anywhere (Leo 2026-11-22, ask-931361017e). The rows come from `SettingsSchema.quickToggleGroups`
/// and are rebuilt each time the menu opens, so the checkmarks show the value in effect and a new
/// schema row appears with no edit here. A click flips the switch through
/// `palette.toggleSetting` (the guarded `setSetting`); a managed row is disabled. The last row
/// runs `openSettings` at Settings > Customize.
@MainActor
public final class CustomizationsMenu: NSObject, NSMenuDelegate {
    private let settings: @MainActor () -> SettingsController?
    private let registry: ActionRegistry

    private init(registry: ActionRegistry, settings: @escaping @MainActor () -> SettingsController?) {
        self.settings = settings
        self.registry = registry
    }

    /// The submenu's item; it keeps its delegate alive (`representedObject`: `NSMenu.delegate` is weak).
    public static func item(registry: ActionRegistry, settings: @escaping @MainActor () -> SettingsController?) -> NSMenuItem {
        let owner = CustomizationsMenu(registry: registry, settings: settings)
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
                guard let row = registry.makeMenuItem(for: "palette.toggleSetting",
                    arguments: ["setting": .string(descriptor.id)]) else { continue }
                row.title = descriptor.title
                row.toolTip = descriptor.help
                row.state = settings?.isOn(descriptor) == true ? .on : .off
                row.isEnabled = settings.map { !$0.isLocked(descriptor) } ?? false
                menu.addItem(row)
            }
        }
        menu.addItem(.separator())
        if let all = registry.makeMenuItem(for: "openSettings", arguments: ["setting": .string("card.customizeChecklist")]) {
            all.title = SettingsWindowStrings.allCustomizations
            menu.addItem(all)
        }
    }
}
