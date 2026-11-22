public import CmuxNextCompat
import CmuxNextWakeups

/// A clock that moves only when the test advances it: the one test clock of the CmuxNext test
/// targets (debounces, dwell and hover delays, ``DemandTimer`` deadlines, publish pacing).
///
/// A wall clock on a loaded runner stretches each step past the delays under test; this clock
/// has no time of its own, so a test controls every deadline. Code under test takes it as its
/// injected `any Clock<Duration>`; the test waits until that code is asleep on it, then moves it.
///
/// ```swift
/// let clock = ManualClock()
/// let timer = DemandTimer(owner: "test", clock: clock)
/// timer.schedule(after: .milliseconds(100)) { fired = true }
/// try await clock.waitForSleeper()
/// clock.advance(by: .milliseconds(100))
/// ```
public final class ManualClock: Clock, Sendable {
    /// A point on the clock: the time advanced since the clock was made.
    public struct Instant: InstantProtocol {
        /// The time advanced from the clock's start to this instant.
        public var offset: Duration

        /// Makes the instant `offset` after the clock's start.
        public init(offset: Duration) { self.offset = offset }

        public func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        public func duration(to other: Instant) -> Duration { other.offset - offset }
        public static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    /// `waitForSleeper` found no sleeper on the clock within its limit: the code under test never
    /// went to sleep on it, so advancing would test nothing.
    public struct NoSleeper: Error, CustomStringConvertible {
        /// The limit the wait had.
        public let limit: Duration
        public var description: String { "no timer went to sleep on the manual clock within \(limit)" }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// A `waitForSleeper` call that is suspended.
    private struct Watcher {
        /// The latest deadline of the sleeper it waits for; nil for any sleeper.
        let dueBy: Instant?
        let continuation: CheckedContinuation<Bool, Never>

        func wants(_ deadline: Instant) -> Bool { dueBy.map { deadline <= $0 } ?? true }
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
        /// Sleeps cancelled before they were registered.
        var cancelled: Set<Int> = []
        /// `waitForSleeper` calls suspended until a sleeper they want is registered.
        var watchers: [Int: Watcher] = [:]
        var nextID = 0
    }

    /// Short critical sections from any thread, including the clock's synchronous `now` and
    /// `advance`, which an actor would turn into async hops (lock carve-out, CLAUDE.md).
    private let state = Mutex(State())

    /// Makes a clock at offset zero with no sleepers.
    public init() {}

    public var now: Instant { state.withLock { $0.now } }
    public var minimumResolution: Duration { .zero }

    /// Suspends until ``advance(by:)`` reaches `deadline`; throws `CancellationError` when the
    /// calling task is cancelled first.
    // concurrency-allow: the Clock protocol's own requirement; it suspends until the test advances the clock (no thread waits, no timer).
    @concurrent public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state in state.nextID += 1; return state.nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (outcome, watchers): (Result<Void, any Error>?, [CheckedContinuation<Bool, Never>]) = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return (.failure(CancellationError()), []) }
                    if deadline <= state.now { return (.success(()), []) }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    let woken = state.watchers.filter { $0.value.wants(deadline) }
                    for watcher in woken.keys { state.watchers[watcher] = nil }
                    return (nil, woken.values.map(\.continuation))
                }
                for watcher in watchers { watcher.resume(returning: true) }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let sleeper: Sleeper? = state.withLock { state in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// The number of tasks asleep on the clock now.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// The deadlines of the tasks asleep on the clock now. With several timers on one clock,
    /// ``waitForSleeper(within:)`` returns once any of them sleeps; a test that advances past one
    /// timer's deadline first waits until that deadline is here (``waitForSleeper(dueBy:within:)``).
    public var sleeperDeadlines: [Instant] { state.withLock { $0.sleepers.map(\.deadline) } }

    /// Returns once a task is asleep on the clock (at once when one already is).
    ///
    /// Code under test usually reads `now` for its deadline when its own task starts; advancing
    /// before then would move that deadline by the advance. This wait is the signal that the
    /// deadline is set: the sleep registers and resumes it, with no polling. Its only timer is the
    /// failure deadline, a ``DemandTimer`` on the wall clock.
    ///
    /// - Parameter limit: How long to wait (on the wall clock) before failing the test.
    /// - Throws: ``NoSleeper`` when no task went to sleep within `limit`; `CancellationError`.
    public func waitForSleeper(within limit: Duration = .milliseconds(2_500)) async throws {
        try await waitForSleeper(wanted: nil, within: limit)
    }

    /// Returns once a task is asleep on the clock with a deadline at or before `deadline` (at once
    /// when one already is). With several timers on one clock, this is the wait for the timer the
    /// test moves the clock past next: a timer that is due later does not end it.
    ///
    /// ```swift
    /// try await clock.waitForSleeper(dueBy: clock.now.advanced(by: .milliseconds(250)))
    /// clock.advance(by: .milliseconds(250))
    /// ```
    ///
    /// - Parameters:
    ///   - deadline: The latest deadline of the sleeper to wait for.
    ///   - limit: How long to wait (on the wall clock) before failing the test.
    /// - Throws: ``NoSleeper`` when no such task went to sleep within `limit`; `CancellationError`.
    public func waitForSleeper(dueBy deadline: Instant, within limit: Duration = .milliseconds(2_500)) async throws {
        try await waitForSleeper(wanted: deadline, within: limit)
    }

    private func waitForSleeper(wanted dueBy: Instant?, within limit: Duration) async throws {
        let id = state.withLock { state in state.nextID += 1; return state.nextID }
        // A private ledger: the test's failure deadline is not an app wakeup.
        let deadline = DemandTimer(owner: "ManualClock.waitForSleeper", ledger: WakeupLedger())
        let arrived = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let ready: Bool? = state.withLock { state in
                    let watcher = Watcher(dueBy: dueBy, continuation: continuation)
                    if state.sleepers.contains(where: { watcher.wants($0.deadline) }) { return true }
                    if state.cancelled.remove(id) != nil { return false }
                    state.watchers[id] = watcher
                    return nil
                }
                if let ready { return continuation.resume(returning: ready) }
                deadline.schedule(after: limit) { [self] in self.resolveWatcher(id, arrived: false) }
            }
        } onCancel: {
            resolveWatcher(id, arrived: false, cancelling: true)
        }
        deadline.cancel()
        try Task.checkCancellation()
        if !arrived { throw NoSleeper(limit: limit) }
    }

    /// Resumes the `waitForSleeper` call `id` with `arrived` when it still waits; a cancellation
    /// that comes before it registered is kept so the registration returns at once.
    private func resolveWatcher(_ id: Int, arrived: Bool, cancelling: Bool = false) {
        let watcher: CheckedContinuation<Bool, Never>? = state.withLock { state in
            if let watcher = state.watchers.removeValue(forKey: id) { return watcher.continuation }
            if cancelling { state.cancelled.insert(id) }
            return nil
        }
        watcher?.resume(returning: arrived)
    }

    /// Moves the clock on by `duration` and wakes every sleeper whose deadline it reached, in
    /// deadline order.
    public func advance(by duration: Duration) {
        let due: [Sleeper] = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }.sorted { $0.deadline < $1.deadline }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
