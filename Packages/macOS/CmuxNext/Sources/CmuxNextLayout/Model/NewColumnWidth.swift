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
    // Failing-test stub: the rules land in the next commit.
    public static func plan(columns: [LayoutColumn], width: Double, removing: PaneID? = nil) -> NewColumnPlan {
        NewColumnPlan(width: width, resize: nil)
    }
}
