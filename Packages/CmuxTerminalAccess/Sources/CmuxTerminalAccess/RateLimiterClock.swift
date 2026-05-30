import Foundation

/// Monotonic clock seam injected into ``RateLimiter`` so tests can
/// advance time deterministically without sleeping.
///
/// Returns a `ContinuousClock.Instant` because the rate limiter
/// reasons about elapsed time, not wall-clock time — a system-time
/// jump (e.g. NTP) must not refund or starve tokens.
public protocol RateLimiterClock: Sendable {
    /// Current monotonic instant.
    func now() -> ContinuousClock.Instant
}

/// Default monotonic clock backed by `ContinuousClock.now`.
public struct DefaultRateLimiterClock: RateLimiterClock {
    /// Creates a default clock.
    public init() {}

    /// Returns `ContinuousClock.now`.
    public func now() -> ContinuousClock.Instant { .now }
}
