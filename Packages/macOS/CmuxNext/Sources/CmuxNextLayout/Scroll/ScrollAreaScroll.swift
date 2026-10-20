public import CoreGraphics

/// The horizontal scroll of one scroll area (plans/cmux-next/scroll-areas-DESIGN.md S5): the
/// column scroll reducer behind a small adapter, as ``RowScroll`` is for rows. The area's cells
/// are the reducer's columns, measured from the window's leading edge, so reveal, camera anchor,
/// snapping and focus-after-scroll are the column strip's rules.
public nonisolated struct ScrollAreaScroll: Hashable, Sendable {
    public var state = ColumnScrollState()

    public init() {}

    /// The area as a strip the reducer reads.
    public func strip(_ area: ScrollAreaGeometry) -> ColumnStrip {
        ColumnStrip(columns: [], viewportWidth: area.window.width, contentWidth: area.contentWidth, gap: 0)
    }
}
