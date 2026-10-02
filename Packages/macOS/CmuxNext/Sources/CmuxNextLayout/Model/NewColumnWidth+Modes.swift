public import CmuxNextDesign

/// New column widths per `layout.newColumnWidth`
/// (plans/cmux-next/column-sizing.md).
extension NewColumnWidth {
    /// The plan for a column opening next to `anchor` on a screen with
    /// `columns`. `visible` are the scrolling columns the viewport shows
    /// now; `fixedWidth` is `layout.defaultColumnWidth`.
    ///
    /// - `matchCurrent`: the anchor column's width (a split-tree screen
    ///   counts as one full-width column); no column resizes.
    /// - `fixed`: `fixedWidth`, with the lone full-width column rule
    ///   (`plan(columns:width:removing:)`).
    /// - `fitScreen`: the visible scrolling columns (with the anchor's) and
    ///   the new one share the strip equally; each visible column whose
    ///   width differs resizes. Sticky columns never resize.
    public static func plan(mode: NewColumnWidthMode, columns: [LayoutColumn], anchor: ColumnID?, visible: [ColumnID],
                            fixedWidth: Double, removing: PaneID? = nil) -> NewColumnPlan {
        NewColumnPlan(width: fixedWidth, resizes: [])
    }
}
