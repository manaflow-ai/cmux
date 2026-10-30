import Foundation

/// Spacing between retries after a real failure: exponential, capped and
/// jittered. Every retry and reconnect loop in CmuxNext uses it
/// (plans/cmux-next/idle-wakeups.md). A retry loop must first wait for an
/// event that can make the retry succeed when one exists (the socket
/// appears, the process exits, the network returns); Backoff only spaces
/// attempts, it is never a poll period.
public struct Backoff: Sendable {
    /// The first delay; always positive.
    public var initial: Duration
    /// The longest delay; at least ``initial``.
    public var maximum: Duration
    /// How much each delay grows over the one before it; at least 1.
    public var multiplier: Double
    /// Fraction of the delay drawn at random, in 0...1 (0.2: ±20%).
    public var jitter: Double
    /// Full jitter (``fullJitter(initial:maximum:random:)``): each delay is drawn from 0 up to the capped
    /// exponential base, so many waiters that failed together never re-send together.
    public private(set) var full = false
    /// Attempts since the last ``reset()``: the exponent of the next delay.
    public private(set) var attempt = 0
    /// A retry table that is not geometric (5 s, 15 s, 60 s, ...), in order, the last step
    /// repeating; nil grows `initial` by `multiplier` up to `maximum`.
    public private(set) var steps: [Duration]?
    private var random: @Sendable () -> Double

    /// `random` returns a value in 0..<1 (tests inject a constant). Out-of-range
    /// values are corrected, not trapped: an `initial` that is not positive becomes
    /// 100 ms, `maximum` is at least `initial`, `multiplier` at least 1, and
    /// `jitter` is clamped to 0...1 (NaN: 0).
    public init(initial: Duration = .milliseconds(100), maximum: Duration = .seconds(30), multiplier: Double = 2,
                jitter: Double = 0.2, random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        let initial = initial > .zero ? initial : .milliseconds(100)
        self.initial = initial
        self.maximum = max(maximum, initial)
        self.multiplier = multiplier >= 1 ? multiplier : 1
        self.jitter = jitter.isNaN ? 0 : min(max(jitter, 0), 1)
        self.random = random
    }

    /// A backoff that walks a retry table: `steps[0]`, `steps[1]`, ..., then the last step again,
    /// each spread by `jitter` as the geometric one is. An empty table waits zero, and a step below
    /// zero is zero; `initial` and `maximum` are the table's first and largest steps.
    public init(steps: [Duration], jitter: Double = 0.2,
                random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        let table = steps.isEmpty ? [Duration.zero] : steps.map { max($0, .zero) }
        initial = table[0]
        maximum = table.max() ?? .zero
        multiplier = 1
        self.jitter = jitter.isNaN ? 0 : min(max(jitter, 0), 1)
        self.steps = table
        self.random = random
    }

    /// Full-jitter exponential spacing (a re-send that only repairs a lost request): attempt n waits a uniform
    /// draw in 0..<min(`maximum`, `initial` * 2^n).
    public static func fullJitter(initial: Duration, maximum: Duration,
                                  random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) -> Backoff {
        var backoff = Backoff(initial: initial, maximum: maximum, multiplier: 2, jitter: 1, random: random)
        backoff.full = true
        return backoff
    }

    /// The delay before the next attempt; grows until `maximum` (or walks ``steps``).
    public mutating func next() -> Duration {
        if let steps {
            let base = steps[min(attempt, steps.count - 1)].inSeconds
            attempt += 1
            return .seconds(max(base + base * jitter * (random() * 2 - 1), 0))
        }
        let base = min(initial.inSeconds * pow(multiplier, Double(min(attempt, 62))), maximum.inSeconds)
        attempt += 1
        if full { return .seconds(base * min(max(random(), 0), 1)) }
        let spread = base * jitter * (random() * 2 - 1)
        return .seconds(min(max(base + spread, initial.inSeconds * (1 - jitter)), maximum.inSeconds))
    }

    /// Call after a success: the next failure starts from `initial` again.
    public mutating func reset() { attempt = 0 }

    /// The slack the system may add to a wait of `step`: max(8 ms, 10% of the
    /// step). 8 ms is Chromium's `kDefaultLeeway` (base/task/task_features.h,
    /// ``WakeLeeway/defaultAlignment``); 10% is the tolerance Apple's Energy
    /// Efficiency Guide asks of a timer. Unlike ``WakeLeeway``, no 1 s cap: a
    /// retry has no deadline a late fire breaks, so a 30 s step may slip 3 s.
    /// The jitter stays; it spreads clients apart, the tolerance lets the kernel
    /// coalesce each one's wake with others.
    public static func tolerance(for step: Duration) -> Duration {
        max(WakeLeeway.defaultAlignment, step / 10)
    }

    /// Sleeps `next()` on `clock` with ``tolerance(for:)`` and records the wait
    /// under `owner`. Throws `CancellationError` when the task is cancelled.
    public mutating func wait(owner: String, clock: any Clock<Duration> = ContinuousClock(),
                              ledger: WakeupLedger = .shared) async throws {
        let delay = next()
        // timer-class-allow: the retry helper's own sleep (flexible: max(8 ms, 10%)); the caller's task posts its main-thread work itself
        try await clock.sleep(for: delay, tolerance: Self.tolerance(for: delay))
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
