import Foundation

/// Spacing between retries after a real failure: exponential, capped and
/// jittered. Every retry and reconnect loop in CmuxNext uses it
/// (plans/cmux-next/idle-wakeups.md). A retry loop must first wait for an
/// event that can make the retry succeed when one exists (the socket
/// appears, the process exits, the network returns); Backoff only spaces
/// attempts, it is never a poll period.
public struct Backoff: Sendable {
    public var initial: Duration
    public var maximum: Duration
    public var multiplier: Double
    /// Fraction of the delay drawn at random, in 0...1 (0.2: ±20%).
    public var jitter: Double
    public private(set) var attempt = 0
    private var random: @Sendable () -> Double

    /// `random` returns a value in 0..<1 (tests inject a constant).
    public init(initial: Duration = .milliseconds(100), maximum: Duration = .seconds(30), multiplier: Double = 2,
                jitter: Double = 0.2, random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        precondition(initial > .zero && maximum >= initial && multiplier >= 1 && (0...1).contains(jitter))
        self.initial = initial
        self.maximum = maximum
        self.multiplier = multiplier
        self.jitter = jitter
        self.random = random
    }

    /// The delay before the next attempt; grows until `maximum`.
    public mutating func next() -> Duration {
        let base = min(initial.inSeconds * pow(multiplier, Double(min(attempt, 62))), maximum.inSeconds)
        attempt += 1
        let spread = base * jitter * (random() * 2 - 1)
        return .seconds(min(max(base + spread, initial.inSeconds * (1 - jitter)), maximum.inSeconds))
    }

    /// Call after a success: the next failure starts from `initial` again.
    public mutating func reset() { attempt = 0 }

    /// Sleeps `next()` on `clock` and records the wait under `owner`.
    /// Throws `CancellationError` when the task is cancelled.
    public mutating func wait(owner: String, clock: any Clock<Duration> = ContinuousClock(),
                              ledger: WakeupLedger = .shared) async throws {
        let delay = next()
        try await clock.sleep(for: delay)
        ledger.record(owner, reason: "backoff")
    }
}

extension Duration {
    /// This duration in seconds, as a Double.
    public var inSeconds: Double {
        let (whole, attos) = components
        return Double(whole) + Double(attos) / 1e18
    }
}
