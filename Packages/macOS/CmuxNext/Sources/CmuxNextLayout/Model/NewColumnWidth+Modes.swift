public import CmuxNextDesign

/// New column widths per `layout.newColumnWidth`
/// (plans/cmux-next/column-sizing.md). No mode resizes a column that is
/// there (R3b): each only picks the new column's width.
extension NewColumnWidth {
    /// The plan for a column opening next to `anchor` on a screen with
    /// `columns`. `visible` are the scrolling columns the viewport shows
    /// now; `fixedWidth` is `layout.defaultColumnWidth`.
    ///
    /// - `matchCurrent`: the anchor column's width (a split-tree screen
    ///   counts as one full-width column).
    /// - `fixed`: `fixedWidth`.
    /// - `fitScreen`: the share the visible scrolling columns (with the
    ///   anchor's) and the new one would each have of the strip.
    ///
    /// In every mode, a screen with no scrolling column (Home's dock alone,
    /// `pinned-dock-alone-v1`) gives the new column the whole strip right of
    /// the dock: width 1. A dock's width is a share of the window, not of
    /// the strip, so copying it left half the strip empty.
    public static func plan(mode: NewColumnWidthMode, columns: [LayoutColumn], anchor: ColumnID?, visible: [ColumnID],
                            fixedWidth: Double, removing: PaneID? = nil) -> NewColumnPlan {
        let scrollingStays = columns.contains { $0.dock == nil && $0.root.panes.contains { $0 != removing } }
        if !columns.isEmpty, !scrollingStays { return NewColumnPlan(width: 1) }
        switch mode {
        case .fixed:
            return plan(width: fixedWidth)
        case .matchCurrent:
            return plan(width: anchor.flatMap { id in columns.first { $0.id == id }?.width } ?? 1.0)
        case .fitScreen:
            let scrolling = Set(columns.filter { $0.dock == nil }.map(\.id))
            var shared = visible.filter(scrolling.contains)
            if let anchor, scrolling.contains(anchor), !shared.contains(anchor) { shared.append(anchor) }
            return plan(width: 1.0 / Double(shared.count + 1))
        }
    }
}
