/// One bounded turn of ``MemoryConsumer/releaseMemory(within:)``: the limit to release down to and the
/// time the turn may take.
///
/// The coordinator makes one slice per call (at most 2 ms on the main thread) from an injected clock,
/// so a consumer never decides how long it runs and a test drives time. The consumer unlinks one
/// entry at a time and stops when ``isExpired`` turns true, returning
/// ``MemoryReleaseProgress/more``; the coordinator calls it again on a later frame.
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
}
