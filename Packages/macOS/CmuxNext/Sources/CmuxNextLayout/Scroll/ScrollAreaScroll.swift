public import CoreGraphics

/// The horizontal scroll of one scroll area (plans/cmux-next/scroll-areas-DESIGN.md S5): the
/// column scroll reducer behind a small adapter, as ``RowScroll`` is for rows. The area's cells
/// are the reducer's columns, measured from the window's leading edge (Rust,
/// cmux-layout-reducer `scroll::ScrollAreaScroll`), so reveal, camera anchor, snapping and
/// focus-after-scroll are the column strip's rules.
public nonisolated struct ScrollAreaScroll {
    /// The area's scroll state.
    public var state = ColumnScrollState(kind: .area)

    /// An area scroll at rest.
    public init() {}

    /// The area as the reducer reads it: one strip column per cell, in window space.
    ///
    /// The reducer names each cell by its first pane, so the camera anchor and remembered focus
    /// follow the cell while it keeps that pane. No gap: cells sit flush.
    public func strip(_ area: ScrollAreaGeometry) -> ColumnStrip {
        let columns = area.cells.map { cell in
            ColumnStrip.Column(id: ColumnID(cell.panes.first?.rawValue ?? ""), frame: cell.frame, panes: cell.panes,
                               paneFrames: cell.paneFrames)
        }
        var strip = ColumnStrip(columns: columns, viewportWidth: area.window.width, contentWidth: area.contentWidth, gap: 0)
        strip.origin = area.window.minX
        return strip
    }
}
