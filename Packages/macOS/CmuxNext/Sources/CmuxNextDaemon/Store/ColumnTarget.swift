import Foundation

/// A column and its row heights as the daemon names them (``DaemonStore/daemonColumnTarget(column:heights:)``):
/// a pending New Column's or New Row's stand-in column and row ids replaced by the daemon's.
public struct ColumnTarget: Sendable, Hashable {
    /// The daemon's column.
    public let column: ColumnID
    /// The row heights, each naming the daemon's row.
    public let heights: [RowHeightValue]
}
