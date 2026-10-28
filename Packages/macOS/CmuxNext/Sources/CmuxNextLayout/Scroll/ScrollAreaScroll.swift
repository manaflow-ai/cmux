public import CoreGraphics

/// The horizontal scroll of one scroll area (plans/cmux-next/scroll-areas-DESIGN.md S5): the
/// column scroll reducer behind a small adapter, as ``RowScroll`` is for rows. The area's cells
/// are the reducer's columns, measured from the window's leading edge, so reveal, camera anchor,
/// snapping and focus-after-scroll are the column strip's rules.
public nonisolated struct ScrollAreaScroll: Hashable, Sendable {
    public var state = ColumnScrollState()

    public init() {}

    /// The area as a strip the reducer reads.
    ///
    /// Each cell is a column whose id is its first pane, so the reducer's camera anchor and
    /// remembered focus follow the cell while it keeps that pane. No gap: cells sit flush.
    public func strip(_ area: ScrollAreaGeometry) -> ColumnStrip {
        let left = area.window.minX
        func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -left, dy: 0) }
        let columns = area.cells.map { cell in
            ColumnStrip.Column(id: ColumnID("area-cell:\(cell.panes.first?.rawValue ?? "")"), frame: local(cell.frame), panes: cell.panes,
                               paneFrames: cell.paneFrames.mapValues(local))
        }
        return ColumnStrip(columns: columns, viewportWidth: area.window.width, contentWidth: area.contentWidth, gap: 0)
    }
}
