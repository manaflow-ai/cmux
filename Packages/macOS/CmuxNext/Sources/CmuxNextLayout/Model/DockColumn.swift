/// Which viewport edge a dock holds (plans/cmux-next/dock-column.md for
/// left and right, plans/cmux-next/layout-model.md for top and bottom). A
/// left or right dock is a docked column; a top or bottom dock is a
/// screen-wide band (a docked row) that holds one split tree.
public nonisolated enum DockEdge: String, Hashable, Sendable, CaseIterable {
    case left, right, top, bottom

    /// Top and bottom: the dock is a horizontal band.
    public var isBand: Bool { self == .top || self == .bottom }

    /// Left and top: the dock sits before the strip on its axis.
    public var isLeading: Bool { self == .left || self == .top }
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

    public init(edge: DockEdge = .right, mode: DockMode = .docked, role: DockRole? = nil) {
        self.edge = edge
        self.mode = mode
        self.role = role
    }
}
