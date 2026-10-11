import CmuxNextDesign

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
