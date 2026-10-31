/// One value a modifier drag sets: a split's ratio or a column's width (a share of the strip).
public nonisolated enum DividerDragValue: Hashable, Sendable {
    case ratio(SplitID, Double)
    case width(ColumnID, Double)

    /// What the value belongs to, so a later frame can tell which values it no longer sets.
    public var key: DividerDragValueKey {
        switch self {
        case let .ratio(split, _): .split(split)
        case let .width(column, _): .column(column)
        }
    }
}

/// The split or column a ``DividerDragValue`` sets.
public nonisolated enum DividerDragValueKey: Hashable, Sendable {
    case split(SplitID)
    case column(ColumnID)
}
