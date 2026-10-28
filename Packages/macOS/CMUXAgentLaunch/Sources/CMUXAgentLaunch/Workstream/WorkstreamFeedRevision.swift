/// Mobile cache validator for a workstream journal generation.
///
/// Older Macs packed a row count above a notification revision. Reserve that
/// low lane during migration from row counts to byte counts. Beyond 1 GiB,
/// continue linearly so larger logs remain representable as signed integers.
public struct WorkstreamFeedRevision: Sendable {
    private let workstream: Int

    /// Creates a validator from the store's generation, clamping negatives to zero.
    /// - Parameter workstream: The generation reported by ``WorkstreamStore``.
    public init(workstream: Int) {
        self.workstream = max(0, workstream)
    }

    /// The signed validator sent in both feed snapshots and invalidation events.
    public var value: Int {
        let workstreamValue = UInt64(workstream)
        let legacyLaneLimit = UInt64(Int.max) >> 32
        if workstreamValue <= legacyLaneLimit {
            // Preserve the complete legacy packed namespace, including the
            // low notification lane pinned at its maximum during migration.
            return Int((workstreamValue << 32) | 0xFFFF_FFFF)
        }
        // Signed Int has no representable value above the packed namespace.
        // Saturate rather than wrap negative or regress below an older value.
        return Int.max
    }
}
