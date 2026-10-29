public import CoreGraphics

/// The vertical scroll of one column's rows (plans/cmux-next/rows.md V1, V2):
/// the column scroll reducer behind a small adapter. The reducer speaks
/// column ids, so each live row gets an opaque strip slot id (never derived
/// from the row id) that stays stable while the row lives, which keeps the
/// reducer's camera anchor and remembered focus per row.
public nonisolated struct RowScroll: Hashable, Sendable {
    public var state = ColumnScrollState()
    /// While a pan of the rows shows on their motion container, the offset their views
    /// are laid out at; nil when they are laid out at the camera.
    public var panBase: CGFloat?
    /// The offset the last layout pass laid the rows' views out at.
    public var laidOutOffset: CGFloat = 0
    private var slots: [RowID: ColumnID] = [:]
    private var nextSlot = 0

    public init() {}

    /// The offset the rows' views are laid out at: the pan's base during a pan on the container, else
    /// the camera's presented value.
    public var layoutOffset: CGFloat { panBase ?? state.spring.value }

    /// The row a strip slot stands for.
    public func row(forSlot slot: ColumnID) -> RowID? {
        slots.first { $0.value == slot }?.key
    }

    /// The rows of `column` as a strip on the vertical axis: x and y
    /// swapped and measured from the column's top. Assigns slots to new rows
    /// and drops those of rows that left.
    public mutating func strip(rows stack: RowStackGeometry, column: LayoutColumn, panes: [PaneID: CGRect]) -> ColumnStrip {
        let live = Set(column.rows.map(\.id))
        slots = slots.filter { live.contains($0.key) }
        let top = stack.frame.minY
        func transposed(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minY - top, y: rect.minX, width: rect.height, height: rect.width)
        }
        var columns: [ColumnStrip.Column] = []
        for (row, placed) in zip(column.rows, stack.rows) {
            let rowPanes = row.root.panes
            var frames: [PaneID: CGRect] = [:]
            for pane in rowPanes { frames[pane] = panes[pane].map(transposed) }
            columns.append(ColumnStrip.Column(id: slot(for: row.id), frame: transposed(placed.frame), panes: rowPanes, paneFrames: frames))
        }
        var strip = ColumnStrip(columns: columns, viewportWidth: stack.frame.height, contentWidth: stack.contentHeight, gap: stack.gap)
        strip.axis = .vertical
        return strip
    }

    private mutating func slot(for row: RowID) -> ColumnID {
        if let slot = slots[row] { return slot }
        nextSlot += 1
        let slot = ColumnID("row-slot:\(nextSlot)")
        slots[row] = slot
        return slot
    }
}
