/// Decides which Chromium helper ends are sent (``HelperExitEvent``): the first end of each process type,
/// then at most one more of that type per ``window`` (an hour), so a crash loop costs one event an hour per
/// type, not one per restart. The ends it holds back are counted into the next sent event of the type.
///
/// A pure value on a monotonic clock that the caller passes in (the App's main actor holds it), so tests
/// drive it with plain instants.
///
/// ```swift
/// var limiter = HelperExitRateLimiter()
/// limiter.admit("renderer", at: .now)  // 0: send, none held back
/// limiter.admit("renderer", at: .now)  // nil: held back
/// ```
public nonisolated struct HelperExitRateLimiter: Sendable, Equatable {
    /// The shortest time between two events of one type (default 1 hour).
    public let window: Duration
    private var lastSent: [String: ContinuousClock.Instant] = [:]
    private var heldBack: [String: Int] = [:]

    public init(window: Duration = .seconds(3_600)) {
        self.window = window
    }

    /// Whether an end of `processType` at `now` is sent.
    ///
    /// - Returns: The ends of the type held back since its last event when this one is sent; nil when it
    ///   is held back.
    public mutating func admit(_ processType: String, at now: ContinuousClock.Instant) -> Int? {
        if let last = lastSent[processType], now - last < window {
            heldBack[processType, default: 0] += 1
            return nil
        }
        lastSent[processType] = now
        return heldBack.removeValue(forKey: processType) ?? 0
    }
}
