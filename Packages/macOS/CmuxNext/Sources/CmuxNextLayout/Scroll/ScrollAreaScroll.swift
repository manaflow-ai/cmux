public import CoreGraphics

/// The horizontal scroll of one scroll area (plans/cmux-next/scroll-areas-DESIGN.md S5): the
/// column scroll reducer behind a small adapter, as ``RowScroll`` is for rows. The area's cells
/// are the reducer's columns, measured from the window's leading edge, so reveal, camera anchor,
/// snapping and focus-after-scroll are the column strip's rules.
public nonisolated struct ScrollAreaScroll: Hashable, Sendable {
    public var state = ColumnScrollState()
    /// While a pan of the area shows on its motion container, the offset its views are
    /// laid out at; nil when they are laid out at the camera.
    public var panBase: CGFloat?
    /// The offset the last layout pass laid the area's views out at.
    public var laidOutOffset: CGFloat = 0

    public init() {}

    /// The offset the area's views are laid out at: the pan's base during a pan on the container, else
    /// the camera's presented value.
    public var layoutOffset: CGFloat { panBase ?? state.spring.value }

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
