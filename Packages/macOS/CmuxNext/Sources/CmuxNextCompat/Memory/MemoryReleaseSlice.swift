/// One bounded turn of ``MemoryConsumer/releaseMemory(within:)``: the limit to release down to and the
/// time the turn may take.
///
/// The coordinator makes one slice per call (at most 2 ms on the main thread) from an injected clock,
/// so a consumer never decides how long it runs and a test drives time. The consumer unlinks one
/// entry at a time and stops when ``isExpired`` turns true, returning
/// ``MemoryReleaseProgress/more``; the coordinator calls it again on a later frame. A consumer that
/// frees one costly item per frame returns ``MemoryReleaseProgress/yield`` after it instead.
///
/// ```swift
/// func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
///     let cap = slice.limit.scale(budget.imageCacheBytes)
///     while bytes > cap {
///         if slice.isExpired { return .more }
///         sink.drop(evictOldest())
///     }
///     return .done
/// }
/// ```
public struct MemoryReleaseSlice: Sendable {
    /// The limit to release down to: the consumer keeps at most this share of its full size.
    public let limit: MemoryLimit
    private let expired: @Sendable () -> Bool

    /// Makes a slice that ends when `isExpired` returns true.
    ///
    /// - Parameters:
    ///   - limit: The limit to release down to.
    ///   - isExpired: Whether the turn's time is used up; called between entries.
    public init(limit: MemoryLimit, isExpired: @escaping @Sendable () -> Bool) {
        self.limit = limit
        expired = isExpired
    }

    /// Makes a slice that ends `budget` after now on `clock`.
    ///
    /// - Parameters:
    ///   - limit: The limit to release down to.
    ///   - clock: The clock the budget is measured on (`ContinuousClock` in the app, a fake in tests).
    ///   - budget: How long the turn may take.
    public init<C: Clock>(limit: MemoryLimit, clock: C, budget: C.Duration) {
        let deadline = clock.now.advanced(by: budget)
        self.init(limit: limit) { clock.now >= deadline }
    }

    /// Whether the turn's time is used up; the consumer returns ``MemoryReleaseProgress/more`` then.
    public var isExpired: Bool {
        expired()
    }
}

/// What one ``MemoryConsumer/releaseMemory(within:)`` turn left behind.
public enum MemoryReleaseProgress: Hashable, Sendable {
    /// The consumer is at or under the slice's limit; no more turns are needed.
    case done
    /// The slice ran out first; call again on a later turn.
    case more
    /// The consumer released its one item for this frame (a surface close, a workspace teardown) and
    /// the slice still has time: the consumers after it get the rest of the slice, and the coordinator
    /// calls this one again on a later frame. A consumer that frees one costly item per frame returns
    /// this, so its pace never holds back a cheaper pass ordered after it.
    case yield
    /// The consumer is at the slice's limit except for entries it kept because they are in its working set
    /// (``MemoryLimit/workingSet``); the first of them leaves the working set `agesOutIn` from now. The
    /// coordinator calls it again then, so the limit reaches those entries too once they go idle.
    case keptWorkingSet(agesOutIn: Duration)

    /// The end of a release that kept its in-use entries (``MemoryLimit/scale(_:inUse:)``):
    /// ``keptWorkingSet(agesOutIn:)`` while the longest idle of them is still in the working set, else ``done``.
    ///
    /// - Parameter idle: The longest time since last use among the kept entries in the working set; nil when it
    ///   kept none.
    /// - Returns: What the turn left behind.
    public static func finished(keptInUseIdleFor idle: Duration?) -> MemoryReleaseProgress {
        guard let idle, MemoryLimit.isInWorkingSet(idle: idle) else { return .done }
        return .keptWorkingSet(agesOutIn: MemoryLimit.workingSet - max(idle, .zero))
    }
}
