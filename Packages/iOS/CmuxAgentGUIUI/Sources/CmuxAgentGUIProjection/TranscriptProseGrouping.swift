/// Corner grouping metadata for adjacent prose rows from the same role.
public enum TranscriptProseGrouping: Hashable, Sendable {
    /// The row is not grouped with adjacent prose rows.
    case single
    /// The row starts a same-role group.
    case first
    /// The row is between the first and last rows in a same-role group.
    case middle
    /// The row ends a same-role group.
    case last
}
