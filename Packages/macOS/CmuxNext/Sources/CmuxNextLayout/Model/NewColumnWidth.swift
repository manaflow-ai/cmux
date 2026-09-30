/// A width change for an existing column that goes with a new column.
public nonisolated struct ColumnResize: Hashable, Sendable {
    public var column: ColumnID
    public var width: Double

    public init(column: ColumnID, width: Double) {
        self.column = column
        self.width = width
    }
}

/// The width of a new column, and the width change of an existing column
/// that opening it needs.
public nonisolated struct NewColumnPlan: Hashable, Sendable {
    public var width: Double
    public var resize: ColumnResize?
}

/// Width rules for new columns (plans/cmux-next/niri.md, "Column widths").
public nonisolated enum NewColumnWidth {
    /// A lone column at least this wide counts as full width.
    static let fullWidth = 0.999

    /// The plan for a new column of `width` (a viewport fraction) on a
    /// screen with `columns`. `removing` is a pane that leaves in the same
    /// step (a dragged tab's only pane), so its column may disappear.
    ///
    /// niri keeps every existing width. cmux adds one rule: a lone
    /// full-width column (a workspace that has not scrolled yet) takes the
    /// rest of the viewport, `1 - width`, so both columns are fully
    /// visible. niri proportions include the gaps, so `p + q = 1` fits exactly.
    public static func plan(columns: [LayoutColumn], width: Double, removing: PaneID? = nil) -> NewColumnPlan {
        let range = ColumnWidthPreset.widthRange
        let width = min(max(width, range.lowerBound), range.upperBound)
        guard columns.count == 1, let lone = columns.first, lone.width >= fullWidth,
              lone.root.panes.contains(where: { $0 != removing }) else {
            return NewColumnPlan(width: width, resize: nil)
        }
        let rest = 1 - width
        guard rest >= range.lowerBound else { return NewColumnPlan(width: width, resize: nil) }
        return NewColumnPlan(width: width, resize: ColumnResize(column: lone.id, width: rest))
    }
}
