/// An injected clock read as `ContinuousClock` instants, for code that keeps instants (when a
/// Mac was last shown, when a link went down) and sleeps on the same clock. With the production
/// `ContinuousClock` it is `ContinuousClock.now`; with a test clock, time moves only when the
/// test moves it, for the sleeps and the instants alike.
struct ClockInstants: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant

    init(_ clock: any Clock<Duration>) {
        if clock is ContinuousClock {
            now = { ContinuousClock.now }
        } else {
            now = Self.reading(clock)
        }
    }

    private static func reading<C: Clock<Duration>>(_ clock: C) -> @Sendable () -> ContinuousClock.Instant {
        let base = ContinuousClock.now
        let start = clock.now
        return { base + start.duration(to: clock.now) }
    }
}
