/// Errors produced while creating a transactionally consistent SQLite snapshot.
public enum SQLiteDatabaseSnapshotError: Error, Equatable, Sendable {
    /// The logical database image exceeds the caller's byte limit.
    case snapshotTooLarge(maximumBytes: Int)
    /// SQLite rejected one of the snapshot operations.
    case sqlite(String)
}
