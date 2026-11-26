/// One row of the sidebar's nav block (`sidebar.nav`): a cmux action a look puts at the top of the
/// sidebar, drawn as a plain icon and label row (the Codex app's New chat, Search, Pull requests).
/// Rust validates the setting (cmux-layout-reducer `sidebar_nav`); `action` is a canonical catalog id,
/// and `title` and `symbol` are the look's overrides, nil for the action's own.
public nonisolated struct SidebarNavRow: Hashable, Sendable {
    public var action: String
    public var title: String?
    public var symbol: String?

    public init(action: String, title: String? = nil, symbol: String? = nil) {
        self.action = action
        self.title = title
        self.symbol = symbol
    }
}
