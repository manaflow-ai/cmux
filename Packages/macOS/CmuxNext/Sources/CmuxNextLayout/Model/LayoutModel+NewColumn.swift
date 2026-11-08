public import CmuxNextDesign

// New columns: width from cmux.json `layout.newColumnWidth` (matchCurrent,
// fitScreen, or fixed at `layout.defaultColumnWidth`;
// plans/cmux-next/column-sizing.md, column-scroll.md). A new column never
// resizes a column that is there (R3b).
extension LayoutModel {
    /// Width of a new column as a viewport fraction: the override, else the
    /// live setting while `followsDesignMetrics` is on, else the built-in 0.5.
    public var defaultColumnWidth: Double {
        defaultColumnWidthOverride ?? (followsDesignMetrics ? DesignSettings.shared.defaultColumnWidth : ColumnWidthPreset.defaultWidth)
    }

    /// `layout.newColumnWidth`: the override, else the live setting while
    /// `followsDesignMetrics` is on, else matchCurrent.
    public var newColumnWidthMode: NewColumnWidthMode {
        newColumnWidthModeOverride ?? (followsDesignMetrics ? DesignSettings.shared.newColumnWidth : .matchCurrent)
    }

    /// The width of a new column next to `pane`, by any path (New Column, a tab dropped into a new
    /// column), per `layout.newColumnWidth` (plans/cmux-next/column-sizing.md). It is all a create
    /// sends: the columns there keep their widths and the strip scrolls (R3b). `removing` is a pane
    /// that leaves in the same step.
    public func newColumnWidth(nextTo pane: PaneID, removing: PaneID? = nil) -> Double {
        let layout = screen(containing: pane)?.layout
        // A screen that has never had a second column is a split tree (the daemon root is not a
        // viewport yet): it fills the view like a lone full-width column.
        let columns: [LayoutColumn] = switch layout {
        case .splits(let root)?: [LayoutColumn(id: ColumnID("unscrolled"), width: 1, root: root)]
        case .columns(let columns)?: columns
        case nil: []
        }
        let anchor = columns.first { $0.root.contains(pane) }?.id
        let visible = columns.filter { $0.root.panes.contains(where: visiblePanes.contains) }.map(\.id)
        return NewColumnWidth.plan(mode: newColumnWidthMode, columns: columns, anchor: anchor, visible: visible,
                                   fixedWidth: defaultColumnWidth, removing: removing).width
    }

    /// Requests a new column after `pane`'s column (default: the focused
    /// pane), at the `layout.newColumnWidth` width.
    public func newColumn(after pane: PaneID? = nil) {
        guard let pane = pane ?? focusedPane else { return }
        intentHandler?(.newColumn(after: pane, width: newColumnWidth(nextTo: pane)))
    }

    /// Requests a new column before `pane`'s column (default: the focused pane), at the
    /// `layout.newColumnWidth` width (New Column Left).
    public func newColumn(before pane: PaneID? = nil) {
        guard let pane = pane ?? focusedPane else { return }
        intentHandler?(.newColumnLeft(of: pane, width: newColumnWidth(nextTo: pane)))
    }
}
