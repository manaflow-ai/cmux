import CmuxNextCompat

/// A serial executor that runs its jobs only when the test calls ``runJobs()``.
///
/// The test decides when an actor's next turn comes, as a busy main thread does in the app: a job
/// that arrives while the actor is "busy" waits until the test lets it run. Put a global actor on it
/// to make "the deadline passed while the actor was busy" exact instead of timed:
///
/// ```swift
/// @globalActor
/// actor ManualActor {
///     static let shared = ManualActor()
///     static let executor = ManualSerialExecutor()
///     nonisolated var unownedExecutor: UnownedSerialExecutor { Self.executor.asUnownedSerialExecutor() }
/// }
///
/// try await ManualActor.executor.waitForJob() // the deadline's hop to the actor arrived
/// ManualActor.executor.runJobs()              // the actor's turn
/// ```
public final class ManualSerialExecutor: SerialExecutor, Sendable {
    private struct State {
        var jobs: [UnownedJob] = []
        /// Callers of ``waitForJob()`` parked until a job arrives.
        var waiters = ParkedContinuations<Void>()
    }

    private let state = Mutex(State())

    /// Makes an executor with no jobs.
    public init() {}

    /// Keeps `job` until the test runs it, and wakes every ``waitForJob()`` caller.
    ///
    /// - Parameter job: The job the runtime hands to the executor.
    public func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let waiters = state.withLock { state in
            state.jobs.append(job)
            return state.waiters.takeAll()
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Runs the waiting jobs, and the jobs they enqueue on this executor, on the calling thread.
    ///
    /// - Returns: How many jobs ran. A guard that expects an action NOT to run checks that the
    ///   actor's turn ran something, so it cannot pass because nothing had arrived yet.
    @discardableResult
    public func runJobs() -> Int {
        var ran = 0
        while let job = state.withLock({ state in state.jobs.isEmpty ? nil : state.jobs.removeFirst() }) {
            job.runSynchronously(on: asUnownedSerialExecutor())
            ran += 1
        }
        return ran
    }

    /// Waits until a job waits for its turn: returns at once when one does, or when the next one is
    /// enqueued.
    ///
    /// Advancing a manual clock wakes a deadline's task on the cooperative pool; its next step toward
    /// the actor is this job. The wait is a signal from ``enqueue(_:)``, not a poll. Its only bound is
    /// the current test's time limit: when nothing is ever enqueued (a regression), the time limit
    /// cancels the test and the wait ends with `CancellationError`.
    ///
    /// - Throws: `UnboundedWait` at once when the current test has no time limit (the regression
    ///   would hang the job instead of failing the test); `CancellationError` when the waiting task
    ///   is cancelled.
    public func waitForJob() async throws {
        try requireTimeLimit(for: "ManualSerialExecutor.waitForJob()")
        let id = state.withLock { $0.waiters.newID() }
        try await parkUntilTaken { continuation in
            state.withLock { state in
                ParkDecision(resumeNow: state.waiters.park(id, continuation, arrived: !state.jobs.isEmpty))
            }
        } cancel: {
            state.withLock { $0.waiters.cancel(id) }
        }
    }
}
