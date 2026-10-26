/// What a ``MemoryConsumer`` holds and what freeing it costs, so the coordinator decides how far to
/// limit it and in what order to release it without knowing what it is.
///
/// A port of Chrome's `base/memory_coordinator/traits.h` (the trait names and values are Chrome's;
/// cmux keeps the ones its policies read). The traits are fixed for the life of a registration.
///
/// ```swift
/// let traits = MemoryConsumerTraits(
///     estimatedUsage: .large, dataAccess: .none, retention: .lossless, recreateCost: .cheap,
///     releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: true)
/// ```
public struct MemoryConsumerTraits: Hashable, Sendable, Codable {
    /// About how much memory the consumer holds at its full size (Chrome's `EstimatedMemoryUsage`).
    public enum EstimatedUsage: String, Hashable, Sendable, Codable {
        /// Under 1 MB.
        case small
        /// 1 to 50 MB.
        case medium
        /// Over 50 MB.
        case large
    }

    /// What releasing memory touches besides the memory (Chrome's `ReleaseMemoryDataAccess`).
    public enum DataAccess: String, Hashable, Sendable, Codable {
        /// Only memory: dropping entries, nothing read or written.
        case none
        /// Reads memory or disk to decide what to drop (an LRU walk, a size query).
        case reads
        /// Writes state to disk before it drops it (a snapshot, a spill).
        case readsAndWritesDisk
    }

    /// Whether what the consumer releases can come back exactly (Chrome's `InformationRetention`).
    public enum Retention: String, Hashable, Sendable, Codable {
        /// The state is gone: a discarded page reloads, a scroll position may be lost.
        case lossy
        /// The state can be rebuilt exactly: a decoded image decodes again.
        case lossless
    }

    /// What it costs to rebuild what was released (Chrome's `RecreateMemoryCost`).
    public enum RecreateCost: String, Hashable, Sendable, Codable {
        /// A decode or a lookup.
        case cheap
        /// A reload, a relaunch or a network fetch.
        case expensive
        /// Nothing is rebuilt (a consumer that only stops growing).
        case notApplicable
    }

    /// What releasing costs in CPU on the calling thread (Chrome's `ReleaseMemoryCpuCost`).
    public enum ReleaseCPUCost: String, Hashable, Sendable, Codable {
        /// Unlinking entries.
        case low
        /// Walking or compacting state.
        case high
    }

    /// How much memory the consumer holds at its full size.
    public let estimatedUsage: EstimatedUsage
    /// What releasing touches besides memory.
    public let dataAccess: DataAccess
    /// Whether released state comes back exactly.
    public let retention: Retention
    /// What rebuilding costs.
    public let recreateCost: RecreateCost
    /// What releasing costs in CPU.
    public let releaseCPUCost: ReleaseCPUCost
    /// Whether the consumer keeps state between calls that a limit can shrink (Chrome's `IsStateful`).
    public let isStateful: Bool
    /// Whether the consumer honors ``MemoryLimit`` values between 0 and 100 % rather than only
    /// releasing everything (Chrome's `SupportsMemoryLimit`).
    public let supportsMemoryLimit: Bool

    /// Makes the traits of one consumer.
    public init(
        estimatedUsage: EstimatedUsage,
        dataAccess: DataAccess,
        retention: Retention,
        recreateCost: RecreateCost,
        releaseCPUCost: ReleaseCPUCost,
        isStateful: Bool,
        supportsMemoryLimit: Bool
    ) {
        self.estimatedUsage = estimatedUsage
        self.dataAccess = dataAccess
        self.retention = retention
        self.recreateCost = recreateCost
        self.releaseCPUCost = releaseCPUCost
        self.isStateful = isStateful
        self.supportsMemoryLimit = supportsMemoryLimit
    }

    /// Whether the coordinator scales this consumer's limit by pressure and ``MemorySaverMode``:
    /// stateful and supporting a limit, as Chrome's `MemorySaverMemoryCoordinatorPolicy::ShouldManageConsumer`.
    public var isManaged: Bool {
        isStateful && supportsMemoryLimit
    }
}
