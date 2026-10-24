import CmuxNextCompat

/// A clock that moves only when the test advances it, for any test of a `DemandTimer` deadline or
/// another wait on an injected `Clock`.
///
/// It is the one test clock of the CmuxNext test targets: a fix to its sleep, cancel or advance
/// handling is made here once (private copies in each test target drifted). Waiting for a timer to
/// go to sleep is a signal from ``sleep(until:tolerance:)``, not a poll, so a slow runner only makes
/// the wait longer. The suite's time limit is the only bound on a timer that never sleeps, and
/// ``waitForSleeper()`` refuses to run in a test without one.
///
/// ```swift
/// @Suite(.serialized, .timeLimit(.minutes(1)))
/// struct FadeTests {
///     @Test func theKnobFadesAfterTheRestDelay() async throws {
///         let clock = ManualClock()
///         let timer = DemandTimer(owner: "test.fade", clock: clock, ledger: WakeupLedger())
///         timer.schedule(after: .seconds(1)) { @MainActor in hide() }
///         try await clock.waitForSleeper()
///         clock.advance(by: .seconds(1))
///     }
/// }
/// ```
public final class ManualClock: Clock, Sendable {
    /// A point on the manual clock: the time advanced since the clock was made.
    public struct Instant: InstantProtocol {
        /// The time advanced since the clock was made.
        public var offset: Duration

        /// Makes the instant `offset` after the clock's start.
        ///
        /// - Parameter offset: The time since the clock was made.
        public init(offset: Duration) {
            self.offset = offset
        }

        /// The instant `duration` after this one.
        ///
        /// - Parameter duration: The time to move on by; negative moves back.
        /// - Returns: The later (or earlier) instant.
        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        /// The time from this instant to `other`.
        ///
        /// - Parameter other: The instant to measure to.
        /// - Returns: The duration, negative when `other` is earlier.
        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        /// Whether `lhs` comes before `rhs`.
        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct State {
        var current = Instant(offset: .zero)
        /// Callers of ``sleep(until:tolerance:)``, each tagged with its deadline.
        var sleepers = ParkedContinuations<Instant>()
        /// Callers of ``waitForSleeper()`` parked until a sleeper arrives.
        var waiters = ParkedContinuations<Void>()
    }

    private let state = Mutex(State())

    /// Makes a clock at instant zero with nothing asleep.
    public init() {}

    /// The clock's current instant: zero plus every ``advance(by:)`` so far.
    public var now: Instant {
        state.withLock { $0.current }
    }

    /// Zero: the clock has no granularity of its own.
    public var minimumResolution: Duration {
        .zero
    }

    /// Sleeps until the clock is advanced to `deadline`, or returns at once when it is there already.
    ///
    /// Going to sleep wakes every ``waitForSleeper()`` caller. Cancelling the sleeping task ends the
    /// sleep with `CancellationError`, also when the cancel comes before the sleep starts.
    ///
    /// - Parameters:
    ///   - deadline: The instant to wake at.
    ///   - tolerance: Ignored: the clock moves only in the test's steps.
    /// - Throws: `CancellationError` when the task is cancelled.
    @concurrent public func sleep(until deadline: Instant, tolerance: Duration?) async throws { // concurrency-allow: the Clock requirement a test clock implements; it parks the caller on a continuation, no thread sleeps
        let id = state.withLock { $0.sleepers.newID() }
        try await parkUntilTaken { continuation in
            state.withLock { state in
                if let outcome = state.sleepers.park(id, tag: deadline, continuation, arrived: deadline <= state.current) {
                    return ParkDecision(resumeNow: outcome)
                }
                return ParkDecision(resumeNow: nil, wake: state.waiters.takeAll())
            }
        } cancel: {
            state.withLock { $0.sleepers.cancel(id) }
        }
    }

    /// Waits until a timer is asleep on the clock: returns at once when one is, or when the next one
    /// goes to sleep.
    ///
    /// A timer reads ``now`` for its deadline when its task starts, off the caller's actor: advancing
    /// before then would push its deadline back by the advance, so a test waits for the sleeper first.
    /// The wait is a signal, not a poll. Its only bound is the current test's time limit: when no
    /// timer ever sleeps (a regression), the time limit cancels the test and the wait ends with
    /// `CancellationError`.
    ///
    /// - Throws: `UnboundedWait` at once when the current test has no time limit (the regression
    ///   would hang the job instead of failing the test); `CancellationError` when the waiting task
    ///   is cancelled.
    public func waitForSleeper() async throws {
        try requireTimeLimit(for: "ManualClock.waitForSleeper()")
        let id = state.withLock { $0.waiters.newID() }
        try await parkUntilTaken { continuation in
            state.withLock { state in
                ParkDecision(resumeNow: state.waiters.park(id, continuation, arrived: !state.sleepers.isEmpty))
            }
        } cancel: {
            state.withLock { $0.waiters.cancel(id) }
        }
    }

    /// Moves the clock on by `duration` and wakes every sleeper whose deadline it reached.
    ///
    /// - Parameter duration: The time to move on by.
    public func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.current = state.current.advanced(by: duration)
            let current = state.current
            return state.sleepers.take { $0 <= current }
        }
        for sleeper in due { sleeper.resume() }
    }
}
