import CmuxNextDesign
import CoreGraphics

/// Rows (plans/cmux-next/rows.md). The model keeps no copy of row heights:
/// a divider drag previews locally in the view and its release becomes one
/// `setRowHeights` intent, which the App sends through the store's intent
/// log (mirror + intents, OWNERSHIP-PRINCIPLES.md).
extension LayoutModel {
    /// Rows are on (cmux.json `layout.rows`, O1): the override, else the
    /// live setting while `followsDesignMetrics` is on, else the base style's.
    public var rowsEnabled: Bool {
        rowsEnabledOverride ?? (followsDesignMetrics ? DesignSettings.shared.layoutRows : baseStyle.rowsEnabled)
    }

    /// Sends every row height of `column` (a divider release). Ignored
    /// unless the daemon serves `rows-v1` (`acceptsRowOps`), or when a
    /// height is out of range or a row is missing (the daemon would refuse
    /// it, `row-set-stale`).
    public func setRowHeights(_ column: ColumnID, heights: [RowHeight], fit: Bool) {
        guard acceptsRowOps,
              let rows = screens.lazy.compactMap({ $0.layout.columns.first { $0.id == column } }).first?.rows,
              Set(rows.map(\.id)) == Set(heights.map(\.row)), heights.count == rows.count,
              heights.allSatisfy({ LayoutRow.heightRange.contains($0.height) }),
              !fit || heights.reduce(0, { $0 + $1.height }) == 1000
        else { return }
        emit(.setRowHeights(column, heights: heights, fit: fit))
    }

    /// A row edge's double-click (#57175): every row of `column` gets an even share of the column's height and together
    /// they fit it (`SetRowHeights` with `fit`, rows.md G3 and R4). With `stack` (the column as laid out) a row whose
    /// panes need more than an even share keeps their minimum height and the other rows share the rest
    /// (``EvenSplitRatios/evenShares(of:minimums:)``). Nothing goes out when the heights are even already or when the
    /// rows cannot all fit (more than 10 rows: each needs 100‰).
    public func equalizeRows(_ column: ColumnID, stack: RowStackGeometry? = nil) {
        guard let rows = screens.lazy.compactMap({ $0.layout.columns.first { $0.id == column } }).first?.rows, rows.count > 1,
              let heights = Self.evenRowHeights(rows, stack: stack, style: style),
              heights != rows.map({ RowHeight(row: $0.id, height: $0.height) }) else { return }
        setRowHeights(column, heights: heights, fit: true)
    }

    /// Heights in permille that give `rows` even shares of their column and sum to 1000 (`fit`); nil when more rows
    /// than 1000‰ can hold at 100‰ each. With `stack`, sized for the column's height and gaps
    /// (`RowStackGeometry.pixelHeight`), minimums kept.
    static func evenRowHeights(_ rows: [LayoutRow], stack: RowStackGeometry?, style: LayoutStyle) -> [RowHeight]? {
        let floor = LayoutRow.heightRange.lowerBound, total = 1000
        guard !rows.isEmpty, rows.count * floor <= total else { return nil }
        var shares = Array(repeating: Double(total) / Double(rows.count), count: rows.count)
        if let stack, stack.frame.height > 0 {
            let height = stack.frame.height, gap = stack.gap
            let available = height - gap * CGFloat(rows.count - 1)
            let minimums = rows.map { SplitGeometry.minimumSize(of: $0.root, style: style).height }
            if minimums.reduce(0, +) <= available + 0.5 {
                let sized = EvenSplitRatios.evenShares(of: available, minimums: minimums)
                    .map { Double(($0 + gap) / (height + gap)) * Double(total) }
                if sized.allSatisfy({ $0 >= Double(floor) }) { shares = sized }
            }
        }
        // Whole permille summing to exactly 1000: round down, then hand the rest out by the largest remainders.
        var values = shares.map { Int($0.rounded(.down)) }
        let order = shares.indices.sorted { shares[$0] - Double(values[$0]) > shares[$1] - Double(values[$1]) }
        for index in order.prefix(max(0, total - values.reduce(0, +))) { values[index] += 1 }
        return zip(rows, values).map { RowHeight(row: $0.id, height: $1) }
    }

    /// The height of a new row below `pane`'s row (G3, `matchCurrent`): the
    /// stored height of that row, so a full-height row gives a full-height
    /// new row.
    public func newRowHeight(below pane: PaneID) -> Int {
        guard let column = screen(containing: pane)?.layout.column(containing: pane), let row = column.row(containing: pane) else {
            return LayoutRow.heightRange.upperBound
        }
        return min(max(row.height, LayoutRow.heightRange.lowerBound), LayoutRow.heightRange.upperBound)
    }

    /// Opens a row below `pane`'s row. Refused (false) while rows are off or
    /// the daemon lacks `rows-v1` (O2, capability gating).
    @discardableResult
    public func newRow(below pane: PaneID) -> Bool {
        guard rowsEnabled, acceptsRowOps, screen(containing: pane) != nil else { return false }
        emit(.newRow(below: pane, height: newRowHeight(below: pane)))
        return true
    }
}
