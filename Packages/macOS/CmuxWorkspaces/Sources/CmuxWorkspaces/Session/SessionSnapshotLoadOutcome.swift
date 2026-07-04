/// Result of inspecting a snapshot file on disk.
public enum SessionSnapshotLoadOutcome<SnapshotValue: SessionSnapshotRepresenting>: Sendable {
    /// A usable snapshot was decoded.
    case loaded(SnapshotValue)
    /// No snapshot file on disk: a genuinely clean state.
    case missing
    /// A snapshot file exists but cannot be restored (unreadable data,
    /// decode failure, schema version drift, an anomalous empty window list,
    /// or only non-restorable phantom windows left by an unclean shutdown;
    /// empty states remove the file instead of writing it).
    case unusable
}
