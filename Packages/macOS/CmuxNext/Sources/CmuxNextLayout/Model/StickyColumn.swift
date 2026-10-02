/// Which viewport edge a sticky column holds (plans/cmux-next/sticky-column.md).
public nonisolated enum StickyEdge: String, Hashable, Sendable, CaseIterable {
    case left, right
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
