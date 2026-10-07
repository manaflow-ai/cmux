/// The injected clock for every timeout, backoff and preference window in
/// CmuxLink. Wraps any `Clock<Duration>` so tests drive a manual clock.
public struct LinkClock: Sendable {
    private let elapsed: @Sendable () -> Duration
    private let sleeper: @Sendable (Duration) async throws -> Void

    public init<C: Clock>(_ clock: C) where C.Duration == Duration {
        let start = clock.now
        elapsed = { start.duration(to: clock.now) }
        sleeper = { duration in
            try await clock.sleep(until: clock.now.advanced(by: duration), tolerance: nil)
        }
    }

    /// Time since this clock was created.
    public var now: Duration { elapsed() }

    /// Sleeps for `duration`; throws `CancellationError` when cancelled.
    public func sleep(for duration: Duration) async throws {
        try await sleeper(duration)
    }

    public static var continuous: LinkClock { LinkClock(ContinuousClock()) }
}
