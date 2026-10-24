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
        var waiters = ArrivalWaiters()
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
    public func runJobs() {
        while let job = state.withLock({ state in state.jobs.isEmpty ? nil : state.jobs.removeFirst() }) {
            job.runSynchronously(on: asUnownedSerialExecutor())
        }
    }

    /// Waits until a job waits for its turn: returns at once when one does, or when the next one is
    /// enqueued.
    ///
    /// Advancing a manual clock wakes a deadline's task on the cooperative pool; its next step toward
    /// the actor is this job. The wait is a signal from ``enqueue(_:)``, not a poll. When nothing is
    /// ever enqueued (a regression), the wait ends with `CancellationError` when the test is cancelled
    /// at its suite's `.timeLimit`, so give such a suite one.
    ///
    /// - Throws: `CancellationError` when the waiting task is cancelled.
    public func waitForJob() async throws {
        let id = state.withLock { $0.waiters.newID() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = state.withLock { state in
                    let arrived = !state.jobs.isEmpty
                    return state.waiters.park(id, continuation, arrived: arrived)
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.cancel(id) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}
