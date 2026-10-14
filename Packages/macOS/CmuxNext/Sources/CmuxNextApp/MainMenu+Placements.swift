import AppKit
import CmuxNextActions

/// The catalog's Edit and Help placements (`mainMenu: .edit` / `.help`),
/// laid out the way Mac apps lay those menus out. An action placed there
/// that no group names still shows, after the grouped rows.
extension MainMenu {
    /// Edit › Find ›, grouped as in Safari, Chrome and Xcode: the find
    /// fields, then stepping through matches, then closing the bar.
    static let findGroups: [[ActionID]] = [
        ["find", "findInDirectory"],
        ["findNext", "findPrevious", "useSelectionForFind"],
        ["hideFind"],
    ]

    /// Help: the documentation first (Mac apps' "<App> Help"), then
    /// learning and news, then reports, then sharing.
    static let helpGroups: [[ActionID]] = [
        ["help.documentation", "palette.searchShortcuts", "updates.whatsNew"],
        ["sendFeedback"],
        ["help.showCrashLogs", "cloudDiagnostics", "help.featureFlags"],
        ["app.shareCmux"],
    ]

    /// Rows after Select All: the Find submenu, then the other Edit
    /// placements (Toggle Dictation), each under a separator.
    static func editPlacements(_ registry: ActionRegistry) -> [NSMenuItem] {
        var items: [NSMenuItem] = [.separator()]
        let find = groupedItems(findGroups, in: .edit, registry)
        if !find.isEmpty { items.append(submenu(Strings.menuFind, items: find)) }
        items.append(.separator())
        return items + otherItems(besides: findGroups, in: .edit, registry)
    }

    static func helpPlacements(_ registry: ActionRegistry) -> [NSMenuItem] {
        groupedItems(helpGroups, in: .help, registry) + [.separator()] + otherItems(besides: helpGroups, in: .help, registry)
    }

    /// The rows of `groups` placed in `menu`, a separator between groups.
    private static func groupedItems(_ groups: [[ActionID]], in menu: ActionMainMenu, _ registry: ActionRegistry) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for group in groups {
            let rows = group.filter { registry.descriptor(for: $0)?.mainMenu == menu }.compactMap { registry.makeMenuItem(for: $0) }
            if rows.isEmpty { continue }
            if !items.isEmpty { items.append(.separator()) }
            items += rows
        }
        return items
    }

    /// Actions placed in `menu` that no group names, in catalog order.
    private static func otherItems(besides groups: [[ActionID]], in menu: ActionMainMenu, _ registry: ActionRegistry) -> [NSMenuItem] {
        let grouped = Set(groups.joined())
        return registry.descriptors.filter { $0.mainMenu == menu && !grouped.contains($0.id) }.compactMap { registry.makeMenuItem(for: $0.id) }
    }
}
