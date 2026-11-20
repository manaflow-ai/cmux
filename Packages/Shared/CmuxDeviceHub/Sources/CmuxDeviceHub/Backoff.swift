public import Foundation

/// Spacing between reconnects after a real failure: exponential, capped and
/// jittered (the macOS app's `CmuxNextWakeups.Backoff`, without its wakeup
/// ledger). The socket first waits for an event that can make a retry succeed;
/// Backoff only spaces attempts, it is never a poll period.
public struct Backoff: Sendable {
    public var initial: Duration
    public var maximum: Duration
    public var multiplier: Double
    /// Fraction of the delay drawn at random, in 0...1 (0.2: ±20%).
    public var jitter: Double
    public private(set) var attempt = 0
    private var random: @Sendable () -> Double

    /// `random` returns a value in 0..<1 (tests inject a constant). Out-of-range
    /// values are corrected, not trapped, as in the macOS app's Backoff.
    public init(initial: Duration = .milliseconds(100), maximum: Duration = .seconds(30), multiplier: Double = 2,
                jitter: Double = 0.2, random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        let initial = initial > .zero ? initial : .milliseconds(100)
        self.initial = initial
        self.maximum = max(maximum, initial)
        self.multiplier = multiplier >= 1 ? multiplier : 1
        self.jitter = jitter.isNaN ? 0 : min(max(jitter, 0), 1)
        self.random = random
    }

    /// The delay before the next attempt; grows until `maximum`.
    public mutating func next() -> Duration {
        let base = min(initial.hubSeconds * pow(multiplier, Double(min(attempt, 62))), maximum.hubSeconds)
        attempt += 1
        let spread = base * jitter * (random() * 2 - 1)
        return .seconds(min(max(base + spread, initial.hubSeconds * (1 - jitter)), maximum.hubSeconds))
    }

    /// Call after a success: the next failure starts from `initial` again.
    public mutating func reset() { attempt = 0 }

    /// Sleeps `next()` on `clock`. Throws `CancellationError` when the task is cancelled.
    public mutating func wait(owner _: String, clock: any Clock<Duration> = ContinuousClock()) async throws {
        try await clock.sleep(for: next())
    }
}

extension Duration {
    /// This duration in seconds, as a Double.
    var hubSeconds: Double {
        let (whole, attos) = components
        return Double(whole) + Double(attos) / 1e18
    }
}
