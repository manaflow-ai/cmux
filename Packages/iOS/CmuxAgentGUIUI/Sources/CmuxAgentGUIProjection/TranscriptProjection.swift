/// Rows plus the identity diff from a previous projection.
public struct TranscriptProjection: Hashable, Sendable {
    /// Rows in chronological order, with the oldest visual row at index zero.
    public let rows: [TranscriptRow]
    /// Identity-level diff from the previous projection.
    public let diff: TranscriptProjectionDiff

    /// Creates a projection result.
    /// - Parameters:
    ///   - rows: Rows in collection-view order.
    ///   - diff: Identity-level diff from the previous projection.
    public init(rows: [TranscriptRow], diff: TranscriptProjectionDiff) {
        self.rows = rows
        self.diff = diff
    }
}
