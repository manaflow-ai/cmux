public import CoreGraphics

/// The vertical scroll of one column's rows (plans/cmux-next/rows.md V1, V2):
/// the column scroll reducer behind a small adapter. The reducer (Rust,
/// cmux-layout-reducer `scroll::RowScroll`) transposes the rows into a strip on
/// the vertical axis and gives each live row an opaque slot that stays stable
/// while the row lives, which keeps its camera anchor and remembered focus per row.
public nonisolated struct RowScroll {
    /// The rows' scroll state.
    public var state = ColumnScrollState(kind: .rows)

    /// A row scroll at rest.
    public init() {}

    /// The rows of `column` as the reducer reads them: one strip column per row,
    /// in window space (its id the row id), measured by the stack.
    public func strip(rows stack: RowStackGeometry, column: LayoutColumn, panes: [PaneID: CGRect]) -> ColumnStrip {
        var columns: [ColumnStrip.Column] = []
        columns.reserveCapacity(stack.rows.count)
        for (row, placed) in zip(column.rows, stack.rows) {
            let rowPanes = row.root.panes
            var frames: [PaneID: CGRect] = [:]
            for pane in rowPanes { frames[pane] = panes[pane] }
            columns.append(ColumnStrip.Column(id: ColumnID(row.id.rawValue), frame: placed.frame, panes: rowPanes, paneFrames: frames))
        }
        var strip = ColumnStrip(columns: columns, viewportWidth: stack.frame.height, contentWidth: stack.contentHeight, gap: stack.gap)
        strip.axis = .vertical
        strip.origin = stack.frame.minY
        return strip
    }
}
