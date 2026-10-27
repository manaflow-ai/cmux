/// How much of its normal memory a ``MemoryConsumer`` may keep, as a percentage: 100 % is what the
/// consumer itself defines as its full size (its cap from `SubsystemBudget`), 0 % is nothing beyond
/// its working set.
///
/// A port of Chrome's memory limit (`base/memory_coordinator/memory_limit.h` and
/// `base/memory_coordinator/memory_consumer.h`: `kDefaultMemoryLimit`, `memory_limit()` and
/// `memory_limit_ratio()`). The coordinator hands each consumer one value through
/// ``MemoryConsumer/updateMemoryLimit(_:)``; the consumer scales its own caps with ``scale(_:)``.
///
/// ```swift
/// func updateMemoryLimit(_ limit: MemoryLimit) {
///     byteCap = limit.scale(budget.imageCacheBytes)
/// }
/// ```
public struct MemoryLimit: Hashable, Comparable, Sendable, Codable {
    /// The share of the consumer's full size it may keep, 0...100.
    public let percent: Int

    /// Makes the limit `percent` %, clamped to 0...100.
    ///
    /// - Parameter percent: The share of the consumer's full size, in percent.
    public init(percent: Int) {
        self.percent = min(max(percent, 0), 100)
    }

    /// The limit every consumer has until the coordinator says otherwise: its full size
    /// (Chrome's `kDefaultMemoryLimit`, 100).
    public static let `default` = MemoryLimit(percent: 100)

    /// The limit the coordinator gives managed consumers at critical pressure: nothing beyond the
    /// working set. A consumer that acts only at critical pressure (Chrome's urgent page discarding
    /// policy, which acts when `memory_limit() <= CriticalPressureThreshold`) checks
    /// ``isCritical``.
    public static let criticalThreshold = MemoryLimit(percent: 0)

    /// How long an entry stays in its consumer's working set after its last use (p07-memory.md section
    /// 3.A). A limit applies only to entries out of the working set: a lossless consumer never releases
    /// one used this recently, at any limit, critical included.
    public static let workingSet: Duration = .seconds(2)

    /// Whether an entry last used `idle` ago is in the working set, so no limit releases it.
    ///
    /// - Parameter idle: The time since the entry's last use, on the consumer's clock.
    /// - Returns: True while `idle` is under ``workingSet``.
    public static func isInWorkingSet(idle: Duration) -> Bool {
        idle < workingSet
    }

    /// The limit as a fraction, 0...1 (Chrome's `memory_limit_ratio()`).
    public var ratio: Double {
        Double(percent) / 100
    }

    /// Whether the limit is at or below ``criticalThreshold``.
    public var isCritical: Bool {
        self <= Self.criticalThreshold
    }

    /// `capacity` scaled by this limit, rounded down: a 50 % limit on a 64 MiB cache gives 32 MiB, on
    /// 5 entries gives 2. Never overflows, whatever the capacity. A consumer whose entries have use times
    /// keeps its working set on top with ``scale(_:inUse:)``.
    ///
    /// - Parameter capacity: The consumer's full size, in bytes or entries (not negative).
    /// - Returns: How much of it the consumer may keep.
    public func scale(_ capacity: Int) -> Int {
        let capacity = max(capacity, 0)
        return capacity / 100 * percent + capacity % 100 * percent / 100
    }

    /// How many of `capacity` entries a consumer keeps when `inUse` of them are in its working set
    /// (``isInWorkingSet(idle:)``): every entry in use, and this limit's share of the rest. A 50 % limit
    /// on 10 entries with 4 in use keeps 4 + 3; the critical limit keeps the 4. The consumer reports its
    /// in-use entries here and releases its least recently used entries down to the result.
    ///
    /// - Parameters:
    ///   - capacity: The consumer's full size, in entries (not negative).
    ///   - inUse: How many entries it holds that are in the working set.
    /// - Returns: How many entries it may keep, never fewer than `inUse`.
    public func scale(_ capacity: Int, inUse: Int) -> Int {
        let inUse = max(inUse, 0)
        return inUse + scale(max(capacity - inUse, 0))
    }

    /// This limit applied on top of `share`, rounded down: a 50 % pressure limit in a mode whose share
    /// is 75 % gives 37 %.
    ///
    /// - Parameter share: The other limit, such as a ``MemorySaverMode/share``.
    /// - Returns: The product of the two limits.
    public func scaled(by share: MemoryLimit) -> MemoryLimit {
        MemoryLimit(percent: share.scale(percent))
    }

    public static func < (lhs: MemoryLimit, rhs: MemoryLimit) -> Bool {
        lhs.percent < rhs.percent
    }

    /// Reads a bare percentage, clamped like ``init(percent:)``.
    public init(from decoder: any Decoder) throws {
        self.init(percent: try decoder.singleValueContainer().decode(Int.self))
    }

    /// Writes the bare percentage.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(percent)
    }
}
