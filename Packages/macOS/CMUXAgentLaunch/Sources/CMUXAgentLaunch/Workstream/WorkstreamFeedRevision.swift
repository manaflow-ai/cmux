/// Mobile cache validator for a workstream journal generation.
///
/// Older Macs packed a row count above a notification revision. Reserve that
/// low lane during migration from row counts to byte counts. Beyond 1 GiB,
/// continue linearly so larger logs remain representable as signed integers.
/// The old high lane counted decoded rows; the new generation counts bytes.
/// Comparing equal numeric inputs across versions is not a migration comparison:
/// a multi-GB journal contains far fewer rows than bytes.
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
        let legacyCutover: UInt64 = 0x4000_0000
        if workstreamValue >= legacyCutover {
            let cutoverPacked = (legacyCutover << 32) | 0xFFFF_FFFF
            let continuation = cutoverPacked + (workstreamValue - legacyCutover)
            return Int(min(continuation, UInt64(Int.max)))
        }
        return Int((workstreamValue << 32) | 0xFFFF_FFFF)
    }
}
