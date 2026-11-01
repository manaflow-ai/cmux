/// How Cmd-1…9 and Cmd-Ctrl-[ / ] walk the sidebar (SIDEBAR-NUMBERING-AND-
/// STEPPING): `sidebar.numbering`, `sidebar.cmd9`, `sidebar.stepping`,
/// `sidebar.steppingWraps` in cmux.json.
public nonisolated struct SidebarNavigationSettings: Hashable, Sendable {
    /// Which items a walk counts.
    public enum Scope: String, Hashable, Sendable, CaseIterable {
        /// Top-section items, then the rows (Home = 1, App Store = 2, first workspace = 3).
        case allItems
        /// Only the rows (workspaces and collapsed groups), like classic cmux.
        case workspacesOnly
    }

    /// What Cmd-9 picks.
    public enum NinthKey: String, Hashable, Sendable, CaseIterable {
        /// The last item (browser convention).
        case last
        /// The ninth item.
        case ninth
    }

    public var numbering: Scope
    public var cmd9: NinthKey
    public var stepping: Scope
    public var steppingWraps: Bool

    public init(numbering: Scope = .allItems, cmd9: NinthKey = .last, stepping: Scope = .allItems, steppingWraps: Bool = true) {
        self.numbering = numbering
        self.cmd9 = cmd9
        self.stepping = stepping
        self.steppingWraps = steppingWraps
    }
}

extension SidebarNavigationSettings {
    public nonisolated static let defaults = SidebarNavigationSettings()
}
