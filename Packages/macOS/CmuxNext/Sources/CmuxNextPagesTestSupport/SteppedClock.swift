import os

/// A clock whose time a test steps and whose sleeps end only when cancelled, so a test runs each
/// timed pass by hand (the freeze of hidden cmux pages, a page session's timers).
///
/// Copies share one time: give the same clock to the code under test and step it from the test.
///
/// ```swift
/// let clock = SteppedClock()
/// let freezing = CmuxPageFreezing(clock: clock)
/// clock.advance(by: .seconds(31))
/// freezing.replan()
/// ```
public nonisolated struct SteppedClock: Clock, Sendable {
    /// The stepped time, shared by every copy of the clock.
    private nonisolated final class Time: Sendable {
        // Lock carve-out: `Clock.now` is a synchronous nonisolated requirement, read by the code
        // under test on the main actor and by a `DemandTimer`'s sleeping task on the global
        // executor (the default `sleep(for:)` reads `now`), while the test steps it on the main
        // actor. A tiny non-blocking read or add of one value; `Synchronization.Mutex` needs macOS 15.
        let instant: OSAllocatedUnfairLock<ContinuousClock.Instant>

        init(_ start: ContinuousClock.Instant) {
            instant = OSAllocatedUnfairLock(initialState: start)
        }
    }

    private let time: Time

    /// Makes a clock that reads `start` until the test steps it.
    ///
    /// - Parameter start: The first time it reads; the continuous clock's now by default.
    public init(start: ContinuousClock.Instant = .now) {
        time = Time(start)
    }

    /// The time the test stepped to.
    public var now: ContinuousClock.Instant { time.instant.withLock { $0 } }

    /// One nanosecond: the clock has no resolution of its own.
    public var minimumResolution: Duration { .nanoseconds(1) }

    /// Moves the time on by `duration`; no sleep ends (the test runs the pass itself).
    ///
    /// - Parameter duration: How far to step.
    public func advance(by duration: Duration) {
        time.instant.withLock { $0 += duration }
    }

    /// Ends only when its task is cancelled, whatever the deadline.
    ///
    /// - Throws: `CancellationError` once the task is cancelled.
    public func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
        // A stream nobody yields to: iterating it ends only when the task is cancelled.
        let (pending, continuation) = AsyncStream<Void>.makeStream()
        for await _ in pending {}
        withExtendedLifetime(continuation) {}
        try Task.checkCancellation()
    }
}
