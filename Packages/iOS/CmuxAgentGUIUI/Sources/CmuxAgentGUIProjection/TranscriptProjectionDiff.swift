/// Identity-level diff emitted by ``TranscriptProjector``.
public struct TranscriptProjectionDiff: Hashable, Sendable {
    /// Inserted row identities and their indexes in the new projection.
    public let inserted: [TranscriptRowID: Int]
    /// Removed row identities and their indexes in the old projection.
    public let removed: [TranscriptRowID: Int]
    /// Moved row identities with old and new indexes.
    public let moved: [TranscriptRowID: TranscriptRowMove]
    /// Reconfigured row identities whose identity stayed stable but value changed.
    public let updated: Set<TranscriptRowID>
    /// Observable operation count used by incrementality tests.
    public let appliedOperationCount: Int

    /// Creates a projection diff.
    /// - Parameters:
    ///   - inserted: Inserted row identities and new indexes.
    ///   - removed: Removed row identities and old indexes.
    ///   - moved: Moved row identities and old/new indexes.
    ///   - updated: Reconfigured row identities.
    public init(
        inserted: [TranscriptRowID: Int],
        removed: [TranscriptRowID: Int],
        moved: [TranscriptRowID: TranscriptRowMove],
        updated: Set<TranscriptRowID>
    ) {
        self.inserted = inserted
        self.removed = removed
        self.moved = moved
        self.updated = updated
        appliedOperationCount = inserted.count + removed.count + moved.count + updated.count
    }
}
