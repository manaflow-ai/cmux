/// Which viewport edge a dock holds (plans/cmux-next/dock-column.md for
/// left and right, plans/cmux-next/layout-model.md for top and bottom). A
/// left or right dock is a docked column; a top or bottom dock is a
/// screen-wide band (a docked row) that holds one split tree.
public nonisolated enum DockEdge: String, Hashable, Sendable, CaseIterable {
    case left, right, top, bottom

    /// Top and bottom: the dock is a horizontal band.
    public var isBand: Bool { self == .top || self == .bottom }
}

/// How a docked column shares the viewport with the scrolling strip.
public nonisolated enum DockMode: String, Hashable, Sendable, CaseIterable {
    /// The strip's viewport shrinks to leave room; nothing is covered.
    case docked
    /// The column floats over the strip, which keeps the full width.
    case overlay

    public var toggled: DockMode { self == .docked ? .overlay : .docked }
}

/// A column pinned to one edge of the viewport. Daemon `columns[].dock`
/// (`dock-columns-v1`); at most one per edge per screen.
public nonisolated struct DockColumn: Hashable, Sendable {
    public var edge: DockEdge
    public var mode: DockMode
    public var role: DockRole?
    /// `pinned-dock-v1`: the Home dock. Its first tab shows no close button
    /// and its strip no new-tab button: what Home opens goes beside it.
    public var isPinned: Bool
    /// `pinned-dock-v1`: a pinned column takes more tabs (the app turns it on
    /// for Home's dock: tabs drag into and out of it).
    public var allowsTabs: Bool

    public init(edge: DockEdge = .right, mode: DockMode = .docked, role: DockRole? = nil,
                isPinned: Bool = false, allowsTabs: Bool = false) {
        self.edge = edge
        self.mode = mode
        self.role = role
        self.isPinned = isPinned
        self.allowsTabs = allowsTabs
    }

    /// Whether the column takes a tab other than its pinned one.
    public var takesTabs: Bool { !isPinned || allowsTabs }

    /// Whether a pane of this column shows no tab bar while it shows `shownTabs` tabs: a pinned
    /// column (the Home Chief pane) holding only its pinned tab has no strip (Lawrence 2026-10-23:
    /// "home chief should have no tabbar"). A tab dragged into it (`allowsTabs`) brings the strip
    /// back while it is there, so it stays reachable. plans/cmux-next/home-chief-pane.md H1.
    public func hidesTabBar(shownTabs: Int) -> Bool { isPinned && shownTabs <= 1 }
}
