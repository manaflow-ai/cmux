public import CmuxNextCompat

/// Where a consumer stands in ``MemoryCoordinator``'s release order: the cheapest memory to give
/// back goes first, lossy discards go last, so a release pass that runs out of frames has freed the
/// memory that costs the person least.
///
/// The order is cmux's, from Chrome's traits (`base/memory_coordinator/traits.h`): Chrome calls
/// `OnReleaseMemory()` on every consumer at once, while cmux slices the release over frames and so
/// has to pick who goes first. Lower values release first:
///
/// 1. ``Tier``: lossless memory-only and cheap to rebuild, then other lossless memory-only, then
///    lossless that reads, then lossless that writes disk, then every lossy consumer.
/// 2. Low release CPU cost before high.
/// 3. Larger estimated usage before smaller (more bytes per millisecond).
///
/// Equal orders keep registration order.
///
/// ```swift
/// consumers.sort { MemoryReleaseOrder(traits: $0.traits) < MemoryReleaseOrder(traits: $1.traits) }
/// ```
public nonisolated struct MemoryReleaseOrder: Comparable, Hashable, Sendable {
    /// The release tiers, first to last.
    public nonisolated enum Tier: Int, Comparable, Hashable, Sendable {
        /// Lossless, touches only memory, cheap to rebuild (a decoded image cache).
        case memoryOnlyCheap
        /// Lossless, touches only memory, costly or nothing to rebuild.
        case memoryOnly
        /// Lossless, reads memory or disk to decide what to drop.
        case reads
        /// Lossless, writes state to disk before it drops it.
        case writesDisk
        /// Loses state: a discard planner.
        case lossy

        public static func < (lhs: Tier, rhs: Tier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// The consumer's tier.
    public let tier: Tier
    /// What releasing costs in CPU.
    public let releaseCPUCost: MemoryConsumerTraits.ReleaseCPUCost
    /// About how much the consumer holds.
    public let estimatedUsage: MemoryConsumerTraits.EstimatedUsage

    /// The order of a consumer with `traits`.
    ///
    /// - Parameter traits: The consumer's traits.
    public init(traits: MemoryConsumerTraits) {
        tier = Self.tier(of: traits)
        releaseCPUCost = traits.releaseCPUCost
        estimatedUsage = traits.estimatedUsage
    }

    public static func < (lhs: MemoryReleaseOrder, rhs: MemoryReleaseOrder) -> Bool {
        (lhs.tier.rawValue, rank(lhs.releaseCPUCost), rank(lhs.estimatedUsage))
            < (rhs.tier.rawValue, rank(rhs.releaseCPUCost), rank(rhs.estimatedUsage))
    }

    private static func tier(of traits: MemoryConsumerTraits) -> Tier {
        guard traits.retention == .lossless else { return .lossy }
        switch traits.dataAccess {
        case .none: return traits.recreateCost == .cheap ? .memoryOnlyCheap : .memoryOnly
        case .reads: return .reads
        case .readsAndWritesDisk: return .writesDisk
        }
    }

    private static func rank(_ cost: MemoryConsumerTraits.ReleaseCPUCost) -> Int {
        switch cost {
        case .low: 0
        case .high: 1
        }
    }

    private static func rank(_ usage: MemoryConsumerTraits.EstimatedUsage) -> Int {
        switch usage {
        case .large: 0
        case .medium: 1
        case .small: 2
        }
    }
}
