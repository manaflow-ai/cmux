/// A width change for an existing column (a close's `layout.closeSizing`
/// share, `LayoutModel.columnResizes`). A new column never brings one (R3b).
public nonisolated struct ColumnResize: Hashable, Sendable {
    public var column: ColumnID
    public var width: Double

    public init(column: ColumnID, width: Double) {
        self.column = column
        self.width = width
    }
}

/// The width of a new column. It is the whole plan: a new column takes new
/// space and never resizes a column that is there (R3b, Lawrence
/// 2026-10-31: "creating new columns must never resize existing columns";
/// the daemon stores each column's width and no create sends one).
public nonisolated struct NewColumnPlan: Hashable, Sendable {
    public var width: Double

    public init(width: Double) {
        self.width = width
    }
}

/// Width rules for new columns (plans/cmux-next/column-scroll.md, "Column widths").
public nonisolated enum NewColumnWidth {
    /// The plan for a new column of `width` (a viewport fraction), clamped to
    /// the daemon's range. The columns there keep their widths; the strip
    /// scrolls to show the new one.
    public static func plan(width: Double) -> NewColumnPlan {
        let range = ColumnWidthPreset.widthRange
        return NewColumnPlan(width: min(max(width, range.lowerBound), range.upperBound))
    }
}
