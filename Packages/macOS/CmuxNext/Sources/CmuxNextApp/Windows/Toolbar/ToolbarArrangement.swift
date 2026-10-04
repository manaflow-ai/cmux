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
enum ToolbarArrangement {
    static func arrange(apps: [ToolbarEntry], preference: [ToolbarItemPreference]) -> (visible: [ToolbarEntry], overflow: [ToolbarEntry]) {
        ([], [])
    }
}
