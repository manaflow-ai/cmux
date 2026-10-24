import CmuxNextCompat

/// A clock that moves only when the test advances it, for any test of a `DemandTimer` deadline or
/// another wait on an injected `Clock`.
///
/// It is the one test clock of the CmuxNext test targets: a fix to its sleep, cancel or advance
/// handling is made here once (private copies in each test target drifted). Waiting for a timer to
/// go to sleep is a signal from ``sleep(until:tolerance:)``, not a poll, so a slow runner only makes
/// the wait longer; a timer that never sleeps ends the wait at the suite's time limit.
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
///         await timer.settled()
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

    /// A caller asleep until `deadline`.
    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var current = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
        /// Sleepers whose task was cancelled before they went to sleep.
        var cancelledSleepers: Set<Int> = []
        var lastSleeperID = 0
        /// Callers of ``waitForSleeper()`` parked until a sleeper arrives.
        var waiters = ArrivalWaiters()
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
        let id = state.withLock { state in
            state.lastSleeperID += 1
            return state.lastSleeperID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (outcome, waiters): (Result<Void, any Error>?, [CheckedContinuation<Void, any Error>]) =
                    state.withLock { state in
                        if state.cancelledSleepers.remove(id) != nil { return (.failure(CancellationError()), []) }
                        if deadline <= state.current { return (.success(()), []) }
                        state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                        return (nil, state.waiters.takeAll())
                    }
                if let outcome { continuation.resume(with: outcome) }
                for waiter in waiters { waiter.resume() }
            }
        } onCancel: {
            let sleeper: Sleeper? = state.withLock { state in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelledSleepers.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Waits until a timer is asleep on the clock: returns at once when one is, or when the next one
    /// goes to sleep.
    ///
    /// A timer reads ``now`` for its deadline when its task starts, off the caller's actor: advancing
    /// before then would push its deadline back by the advance, so a test waits for the sleeper first.
    /// The wait is a signal, not a poll. When no timer ever sleeps (a regression), the wait ends with
    /// `CancellationError` when the test is cancelled at its suite's `.timeLimit`, so give such a
    /// suite one.
    ///
    /// - Throws: `CancellationError` when the waiting task is cancelled.
    public func waitForSleeper() async throws {
        let id = state.withLock { $0.waiters.newID() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = state.withLock { state in
                    let arrived = !state.sleepers.isEmpty
                    return state.waiters.park(id, continuation, arrived: arrived)
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.cancel(id) }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock on by `duration` and wakes every sleeper whose deadline it reached.
    ///
    /// - Parameter duration: The time to move on by.
    public func advance(by duration: Duration) {
        let due: [CheckedContinuation<Void, any Error>] = state.withLock { state in
            state.current = state.current.advanced(by: duration)
            let current = state.current
            let due = state.sleepers.filter { $0.deadline <= current }.map { $0.continuation }
            state.sleepers.removeAll { $0.deadline <= current }
            return due
        }
        for sleeper in due { sleeper.resume() }
    }
}
