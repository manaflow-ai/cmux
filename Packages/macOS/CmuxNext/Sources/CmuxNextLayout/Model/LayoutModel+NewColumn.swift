public import CmuxNextDesign

// New columns: width from cmux.json `layout.defaultColumnWidth` (niri
// `default-column-width`), plus the lone full-width column rule
// (`NewColumnWidth.plan`, plans/cmux-next/niri.md "Column widths").
extension LayoutModel {
    /// Width of a new column as a viewport fraction: the override, else the
    /// live setting while `followsDesignMetrics` is on, else the built-in 0.5.
    public var defaultColumnWidth: Double {
        defaultColumnWidthOverride ?? (followsDesignMetrics ? DesignSettings.shared.defaultColumnWidth : ColumnWidthPreset.defaultWidth)
    }

    /// Call right before a new column opens next to `pane` by any path (new
    /// column action, a split with no room, a tab dropped into a new column).
    /// Applies the lone column's width change as a width intent with an
    /// optimistic patch, and returns the width to send with the new column.
    /// `removing` is a pane that leaves in the same step.
    @discardableResult
    public func prepareNewColumn(nextTo pane: PaneID, removing: PaneID? = nil) -> Double {
        let columns = screen(containing: pane)?.layout.columns ?? []
        let plan = NewColumnWidth.plan(columns: columns, width: defaultColumnWidth, removing: removing)
        if let resize = plan.resize {
            setColumnWidth(resize.column, width: resize.width, transaction: .make(), phase: .ended)
        }
        return plan.width
    }

    /// Requests a new column after `pane`'s column (default: the focused
    /// pane), niri-style, at `defaultColumnWidth`.
    public func newColumn(after pane: PaneID? = nil) {
        guard let pane = pane ?? focusedPane else { return }
        let width = prepareNewColumn(nextTo: pane)
        intentHandler?(.newColumn(after: pane, width: width))
    }
}
