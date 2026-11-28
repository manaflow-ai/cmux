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
    ///
    /// Run by cmux-layout-reducer (`layout_model_new_column_plan`; `schemas/layout-model/vectors.json`).
    public static func plan(mode: NewColumnWidthMode, columns: [LayoutColumn], anchor: ColumnID?, visible: [ColumnID],
                            fixedWidth: Double, removing: PaneID? = nil) -> NewColumnPlan {
        struct Request: Encodable {
            var mode: String, columns: [LayoutColumn], anchor: ColumnID?, visible: [ColumnID], fixedWidth: Double
            var removing: PaneID?
        }
        struct Reply: Decodable { var width: Double }
        let reply: Reply? = LayoutRules.call("layout_model_new_column_plan",
                                             Request(mode: mode.rawValue, columns: columns, anchor: anchor,
                                                     visible: visible, fixedWidth: fixedWidth, removing: removing))
        return plan(width: reply?.width ?? fixedWidth)
    }
}
