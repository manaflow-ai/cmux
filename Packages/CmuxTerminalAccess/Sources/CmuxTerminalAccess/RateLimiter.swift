import Foundation

/// Token-bucket rate limiter keyed by arbitrary string (D10).
///
/// The HTTP layer uses keys like `"surface:1#write"`,
/// `"surface:1#stream-open"`, and `"conn:<uuid>#write"`. Buckets are
/// created lazily at full ``burstCapacity`` on first
/// ``acquire(key:)``.
///
/// Per Errata E10/E16, ``acquire(key:)`` is `async throws`: it returns
/// `Void` on success and throws ``TerminalAccessError/rateLimited``
/// when the bucket is empty. Call sites use
/// `try await limiter.acquire(key: ...)` and propagate the typed
/// error into the HTTP response.
///
/// Concurrency is safe — internal state is guarded by an `NSLock`
/// taken inside ``acquire(key:)``. The actor seam is not needed
/// because the body is non-async and non-blocking.
public final class RateLimiter: @unchecked Sendable {
    /// Maximum burst (full bucket) in tokens.
    public let burstCapacity: Double
    /// Token refill rate in tokens per second.
    public let refillPerSecond: Double

    private let clock: any RateLimiterClock
    private let lock = NSLock()

    private struct Bucket {
        var tokens: Double
        var updated: ContinuousClock.Instant
    }

    private var buckets: [String: Bucket] = [:]

    /// Creates a token-bucket limiter.
    ///
    /// - Parameters:
    ///   - burstCapacity: Maximum tokens a bucket can hold. New
    ///     buckets start full.
    ///   - refillPerSecond: Refill rate.
    ///   - clock: Monotonic clock seam (default: ``DefaultRateLimiterClock``).
    public init(
        burstCapacity: Int,
        refillPerSecond: Double,
        clock: any RateLimiterClock = DefaultRateLimiterClock()
    ) {
        self.burstCapacity = Double(burstCapacity)
        self.refillPerSecond = refillPerSecond
        self.clock = clock
    }

    /// Spends one token from `key`'s bucket.
    ///
    /// - Throws: ``TerminalAccessError/rateLimited`` when the bucket
    ///   does not have a full token available.
    public func acquire(key: String) async throws {
        let now = clock.now()
        lock.lock()
        var state = buckets[key] ?? Bucket(tokens: burstCapacity, updated: now)
        let elapsed = Self.seconds(from: state.updated, to: now)
        state.tokens = min(burstCapacity, state.tokens + max(0, elapsed) * refillPerSecond)
        state.updated = now
        if state.tokens >= 1 {
            state.tokens -= 1
            buckets[key] = state
            lock.unlock()
            return
        }
        buckets[key] = state
        lock.unlock()
        throw TerminalAccessError.rateLimited
    }

    /// Converts a `ContinuousClock` interval to seconds (TimeInterval).
    private static func seconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Double {
        let dur = start.duration(to: end)
        let comps = dur.components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1.0e18
    }
}
