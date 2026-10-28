import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

/// A time limit raced against async work: the R-timer recipe's helper for "a sleep in a race"
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, "Recipes").
///
/// The first of {the work's result, the limit, the caller's cancellation} resumes the caller; the work is cancelled
/// when it loses and its late result is dropped. A task group would instead wait for a loser that ignores
/// cancellation, so its deadline could become a hang (check-concurrency's task-group rule). The limit sleeps on the
/// injected clock with ``WakeLeeway``'s tolerance for the limit by default, as ``DemandTimer`` does: a timeout is a
/// flexible, no-sooner deadline, as a request deadline is in Chromium (`kFlexibleNoSooner`, base/task/delay_policy.h).
/// Each expired limit is one wakeup in the ledger under its label.
///
/// ```swift
/// let reply = try await Deadline(.seconds(5)).run("daemon.hello") { try await connection.hello() }
/// let workspace = await Deadline(timeout, clock: clock).value("store.reopen") { await store.appearance(of: id) }
/// ```
public struct Deadline: Sendable {
    /// The limit passed before the work finished.
    public struct Exceeded: Error, Sendable, Equatable, CustomStringConvertible {
        /// The race's label.
        public let label: String
        /// The limit it had.
        public let limit: Duration

        /// The exceeded limit of the race named `label`.
        public init(label: String, limit: Duration) {
            self.label = label
            self.limit = limit
        }

        public var description: String { "\(label) missed its \(limit) deadline" }
    }

    /// How long the work may take.
    public let limit: Duration
    private let tolerance: Duration
    private let clock: any Clock<Duration>
    private let ledger: WakeupLedger

    /// - Parameters:
    ///   - limit: How long the work may take.
    ///   - tolerance: How late the limit may expire. nil (the default) is
    ///     ``WakeLeeway/window(delay:policy:alignment:)``'s tolerance for `limit`; `.zero` asks for exact timing.
    ///   - clock: The clock the limit runs on (tests inject a manual one).
    ///   - ledger: Where an expired limit is counted.
    public init(_ limit: Duration, tolerance: Duration? = nil, clock: any Clock<Duration> = ContinuousClock(),
                ledger: WakeupLedger = .shared) {
        self.limit = limit
        self.tolerance = tolerance ?? WakeLeeway.window(delay: limit).tolerance
        self.clock = clock
        self.ledger = ledger
    }

    /// The work's result, or ``Exceeded`` when the limit passes first.
    ///
    /// - Parameters:
    ///   - label: Names the race in the error and the ledger.
    ///   - onTimeout: Runs when the limit wins, before the caller resumes: tears down work that does not observe
    ///     cancellation (a socket, a pipe read).
    ///   - operation: The work. It is cancelled when the limit or the caller's cancellation wins.
    /// - Throws: ``Exceeded``, `CancellationError` when the caller is cancelled first, or the work's error.
    public func run<T: Sendable>(_ label: String, onTimeout: @escaping @Sendable () -> Void = {},
                                 _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let race = Race<T>()
        let limit = limit
        let tolerance = tolerance
        let clock = clock
        let ledger = ledger
        return try await withTaskCancellationHandler {
            try await withOnceThrowingContinuation { (continuation: OnceContinuation<T, any Error>) in
                race.begin(continuation)
                let work = Task {
                    do {
                        race.finish(.success(try await operation()))
                    } catch {
                        race.finish(.failure(error))
                    }
                }
                let timer = Task {
                    // timer-class-allow: this is the Deadline helper recipe R-timer sends sleeps in races to; the race runs off main
                    do { try await clock.sleep(for: limit, tolerance: tolerance) } catch { return }
                    ledger.record(label, reason: "deadline")
                    race.finish(.failure(Exceeded(label: label, limit: limit)), first: onTimeout)
                }
                race.adopt([work, timer])
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    /// The work's value, or nil when the limit or the caller's cancellation comes first.
    ///
    /// - Parameters:
    ///   - label: Names the race in the ledger.
    ///   - operation: The work. It is cancelled when it loses.
    public func value<T: Sendable>(_ label: String, _ operation: @escaping @Sendable () async -> T) async -> T? {
        do {
            return try await run(label) { await operation() }
        } catch {
            return nil
        }
    }

    /// One race's outcome, delivered once. Short critical sections from any thread (the work, the limit and the
    /// cancellation handler each finish from their own), as CmuxNextCompat's `Mutex` allows.
    private final class Race<T: Sendable>: Sendable {
        private struct State {
            var continuation: OnceContinuation<T, any Error>?
            /// The outcome when it came before the continuation (a caller cancelled before the race began).
            var early: Result<T, any Error>?
            var done = false
            var tasks: [Task<Void, Never>] = []
        }

        private let state = Mutex(State())

        func begin(_ continuation: OnceContinuation<T, any Error>) {
            let early: Result<T, any Error>? = state.withLock { state in
                if let early = state.early { return early }
                state.continuation = continuation
                return nil
            }
            if let early { continuation.resume(with: early) }
        }

        /// Keeps the racers for cancellation; cancels them at once when the race already ended.
        func adopt(_ tasks: [Task<Void, Never>]) {
            let ended = state.withLock { state in
                if !state.done { state.tasks = tasks }
                return state.done
            }
            if ended { for task in tasks { task.cancel() } }
        }

        /// Ends the race with `result` when it is the first outcome: runs `first`, cancels the racers, then resumes
        /// the caller, so the caller never runs while a loser is still live. A later outcome is dropped.
        func finish(_ result: Result<T, any Error>, first: () -> Void = {}) {
            let won: (OnceContinuation<T, any Error>?, [Task<Void, Never>])? = state.withLock { state in
                guard !state.done else { return nil }
                state.done = true
                let continuation = state.continuation
                if continuation == nil { state.early = result }
                defer {
                    state.continuation = nil
                    state.tasks = []
                }
                return (continuation, state.tasks)
            }
            guard let won else { return }
            let (continuation, tasks) = won
            first()
            for task in tasks { task.cancel() }
            continuation?.resume(with: result)
        }
    }
}
