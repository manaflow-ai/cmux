import AppKit
import CmuxNextActions

/// The catalog's Help placements (`mainMenu: .help`), laid out the way Mac
/// apps lay that menu out. An action placed there that no group names still
/// shows, after the grouped rows. The Edit placements (Find…, Toggle
/// Dictation) stay out of the bar for now: as menu key equivalents they would
/// claim keys a user's Ghostty keybinds and panels expect (cmuxterm-hq#2015 C11).
extension MainMenu {
    /// Help: the documentation first (Mac apps' "<App> Help"), then
    /// learning and news, then reports, then sharing.
    static let helpGroups: [[ActionID]] = [
        ["help.documentation", "palette.searchShortcuts", "updates.whatsNew"],
        ["sendFeedback"],
        ["help.showCrashLogs", "cloudDiagnostics", "help.featureFlags"],
        ["app.shareCmux"],
    ]

    static func helpPlacements(_ registry: ActionRegistry) -> [NSMenuItem] {
        // Keep Support focused; Feature Flags, Cloud Diagnostics and Share remain
        // palette-searchable instead of occupying peer rows in Help.
        MainMenu.compactMainMenuItems(for: .help, registry: registry)
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
