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
    ///   width differs resizes. Docked columns never resize.
    public static func plan(mode: NewColumnWidthMode, columns: [LayoutColumn], anchor: ColumnID?, visible: [ColumnID],
                            fixedWidth: Double, removing: PaneID? = nil) -> NewColumnPlan {
        let range = ColumnWidthPreset.widthRange
        func clamp(_ value: Double) -> Double { min(max(value, range.lowerBound), range.upperBound) }
        switch mode {
        case .fixed:
            return plan(columns: columns, width: fixedWidth, removing: removing)
        case .matchCurrent:
            let width = anchor.flatMap { id in columns.first { $0.id == id }?.width } ?? 1.0
            return NewColumnPlan(width: clamp(width), resizes: [])
        case .fitScreen:
            let scrolling = Set(columns.filter { $0.dock == nil }.map(\.id))
            var shared = visible.filter(scrolling.contains)
            if let anchor, scrolling.contains(anchor), !shared.contains(anchor) { shared.append(anchor) }
            let share = clamp(1.0 / Double(shared.count + 1))
            let order = columns.map(\.id)
            let resizes = shared.sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
                .compactMap { id -> ColumnResize? in
                    guard let column = columns.first(where: { $0.id == id }), abs(column.width - share) > 0.001 else { return nil }
                    return ColumnResize(column: id, width: share)
                }
            return NewColumnPlan(width: share, resizes: resizes)
        }
    }
}
