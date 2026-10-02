/// Which viewport edge a dock holds (plans/cmux-next/sticky-column.md for
/// left and right, plans/cmux-next/layout-model.md for top and bottom). A
/// left or right dock is a sticky column; a top or bottom dock is a
/// screen-wide band (a sticky row) that holds one split tree.
public nonisolated enum StickyEdge: String, Hashable, Sendable, CaseIterable {
    case left, right, top, bottom

    /// Top and bottom: the dock is a horizontal band.
    public var isBand: Bool { self == .top || self == .bottom }

    /// Left and top: the dock sits before the strip on its axis.
    public var isLeading: Bool { self == .left || self == .top }
}

/// How a sticky column shares the viewport with the scrolling strip.
public nonisolated enum StickyMode: String, Hashable, Sendable, CaseIterable {
    /// The strip's viewport shrinks to leave room; nothing is covered.
    case docked
    /// The column floats over the strip, which keeps the full width.
    case overlay

    public var toggled: StickyMode { self == .docked ? .overlay : .docked }
}

/// A column pinned to one edge of the viewport. Daemon `columns[].sticky`
/// (`sticky-columns-v1`); at most one per edge per screen.
public nonisolated struct StickyColumn: Hashable, Sendable {
    public var edge: StickyEdge
    public var mode: StickyMode

    public init(edge: StickyEdge = .right, mode: StickyMode = .docked) {
        self.edge = edge
        self.mode = mode
    }
}
