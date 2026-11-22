import CmuxNextActions

/// One toolbar band item (titlebar-area.md 3): built-in items are ordinary
/// entries, app items come from manifest `contributes.toolbarItems`.
struct ToolbarEntry: Hashable {
    var id: String
    var action: ActionID
    var symbol: String
    var title: String
    var appID: String?
    var order: Int?
    /// The built-in item this app button can replace when the user picks it.
    var overrides: String?
}

/// One row of the `toolbar.items` setting, in the user's order.
struct ToolbarItemPreference: Hashable {
    var id: String
    var hidden = false
    /// A catalog action that replaces the item's own.
    var action: ActionID?
    /// An app item (its id) the user picked as this built-in item's behavior.
    var use: String?
}

/// Places the band's items: visible in order, plus the overflow menu.
/// The sidebar toggle is always first and never hidden (R68); the user's
/// `toolbar.items` order comes next, then unlisted items in default order
/// (built-ins, then app items by `order`); at most `visibleAppItems` app
/// items show and the rest go to the overflow menu. An app button with
/// `overrides` never shows on its own: it replaces the built-in item's
/// behavior only when the user picks it (`use`).
enum ToolbarArrangement {
    static let toggleID = "sidebar.toggle"
    static let visibleAppItems = 3

    /// The built-in entries. An empty title means the action's own title.
    static let builtIns = [
        ToolbarEntry(id: toggleID, action: "toggleSidebar", symbol: "sidebar.left", title: ""),
        ToolbarEntry(id: "nav.back", action: "focusHistoryBack", symbol: "chevron.left", title: ""),
        ToolbarEntry(id: "nav.forward", action: "focusHistoryForward", symbol: "chevron.right", title: ""),
    ]

    static func arrange(apps: [ToolbarEntry], preference: [ToolbarItemPreference]) -> (visible: [ToolbarEntry], overflow: [ToolbarEntry]) {
        let alternatives = apps.filter { $0.overrides != nil }
        let appItems = apps.filter { $0.overrides == nil }.enumerated()
            .sorted { ($0.element.order ?? .max, $0.offset) < ($1.element.order ?? .max, $1.offset) }.map(\.element)
        let defaults = builtIns + appItems
        let byID = Dictionary(defaults.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let prefs = Dictionary(preference.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        let ordered = (preference.compactMap { byID[$0.id] } + defaults).filter { seen.insert($0.id).inserted }
        var visible: [ToolbarEntry] = [], overflow: [ToolbarEntry] = [], shownApps = 0
        for var entry in ordered {
            let pref = prefs[entry.id]
            let isToggle = entry.id == toggleID
            if pref?.hidden == true, !isToggle { continue }
            if let use = pref?.use, let alternative = alternatives.first(where: { $0.id == use && $0.overrides == entry.id }) {
                entry.action = alternative.action
                entry.symbol = alternative.symbol
                entry.title = alternative.title
            }
            if let action = pref?.action { entry.action = action }
            if isToggle { visible.insert(entry, at: 0); continue }
            if entry.appID != nil {
                guard shownApps < visibleAppItems else { overflow.append(entry); continue }
                shownApps += 1
            }
            visible.append(entry)
        }
        return (visible, overflow)
    }
}
