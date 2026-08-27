/// A bounded executor for accepted control-socket connection jobs.
///
/// The socket listener already delivers accepted descriptors through an
/// ``AsyncStream``. This actor adds admission control at the next boundary:
/// only `maximumConcurrentJobs` connection tasks may be live and only
/// `maximumPendingJobs` additional jobs may wait for a task slot. Jobs are
/// asynchronous, so waiting for a main-actor mutation suspends a task instead
/// of parking an I/O thread. The pool deliberately uses one detached task per
/// *admitted job* (not one thread per connection); Swift's cooperative
/// executor reuses its bounded worker threads for the non-blocking jobs.
///
/// A caller supplies synchronous cleanup for rejected/dropped jobs. An
/// admitted operation owns its descriptor until the operation returns.
public actor ControlClientWorkerPool {
    /// The result of attempting to admit one connection job.
    public enum Submission: Sendable, Equatable {
        /// The operation started immediately.
        case started
        /// The operation is waiting in FIFO order for a running slot.
        case queued
        /// The pool is stopped or its pending queue is full.
        case rejected
    }

    /// Point-in-time pool counters used by diagnostics and behavior tests.
    public struct Metrics: Sendable, Equatable {
        /// Number of operations currently executing.
        public let activeJobs: Int
        /// Number of operations waiting for a slot.
        public let pendingJobs: Int
        /// Highest active-job count observed since initialization.
        public let peakActiveJobs: Int
        /// Number of rejected submissions since initialization.
        public let rejectedJobs: Int
        /// Whether no further jobs can be admitted.
        public let isStopped: Bool

        /// Creates a metrics snapshot.
        public init(
            activeJobs: Int,
            pendingJobs: Int,
            peakActiveJobs: Int,
            rejectedJobs: Int,
            isStopped: Bool
        ) {
            self.activeJobs = activeJobs
            self.pendingJobs = pendingJobs
            self.peakActiveJobs = peakActiveJobs
            self.rejectedJobs = rejectedJobs
            self.isStopped = isStopped
        }
    }

    private struct Job {
        let id: UInt64
        let operation: @Sendable () async -> Void
        let onDrop: @Sendable () -> Void
    }

    private let maximumConcurrentJobs: Int
    private let maximumPendingJobs: Int
    private var activeJobs = 0
    private var peakActiveJobs = 0
    private var rejectedJobs = 0
    private var nextJobID: UInt64 = 1
    private var pendingJobs: [Job] = []
    private var runningTasks: [UInt64: Task<Void, Never>] = [:]
    private var stopped = false

    /// Creates a bounded pool.
    ///
    /// - Parameters:
    ///   - maximumConcurrentJobs: Upper bound on live connection operations.
    ///   - maximumPendingJobs: Upper bound on FIFO jobs waiting for a slot.
    ///
    /// Values are clamped to preserve a useful, finite admission policy even
    /// when a caller forwards an invalid configuration value.
    public init(
        maximumConcurrentJobs: Int = 32,
        maximumPendingJobs: Int = 64
    ) {
        self.maximumConcurrentJobs = max(1, maximumConcurrentJobs)
        self.maximumPendingJobs = max(0, maximumPendingJobs)
    }

    /// Attempts to submit one asynchronous connection operation.
    ///
    /// - Parameter operation: The operation that owns its admitted connection
    ///   until it returns. It must be cancellation-aware when it waits for
    ///   external I/O.
    /// - Parameter onDrop: Synchronous cleanup for a rejected or stopped
    ///   pending operation (typically closing its descriptor).
    /// - Returns: Whether the operation started, queued, or was rejected.
    public func submit(
        _ operation: @escaping @Sendable () async -> Void,
        onDrop: @escaping @Sendable () -> Void = {}
    ) -> Submission {
        guard !stopped else {
            rejectedJobs += 1
            onDrop()
            return .rejected
        }

        let job = Job(id: nextJobID, operation: operation, onDrop: onDrop)
        nextJobID &+= 1
        if activeJobs < maximumConcurrentJobs {
            start(job)
            return .started
        }
        guard pendingJobs.count < maximumPendingJobs else {
            rejectedJobs += 1
            onDrop()
            return .rejected
        }
        pendingJobs.append(job)
        return .queued
    }

    /// Stops admission, cancels live operations, and drops queued operations.
    ///
    /// Running operations keep ownership of their descriptors until their
    /// cancellation handlers return; the operation remains responsible for
    /// closing them.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        let droppedJobs = pendingJobs
        pendingJobs.removeAll(keepingCapacity: false)
        for job in droppedJobs {
            job.onDrop()
        }
        let tasks = Array(runningTasks.values)
        for task in tasks {
            task.cancel()
        }
    }

    /// Returns current admission counters.
    public func metrics() -> Metrics {
        Metrics(
            activeJobs: activeJobs,
            pendingJobs: pendingJobs.count,
            peakActiveJobs: peakActiveJobs,
            rejectedJobs: rejectedJobs,
            isStopped: stopped
        )
    }

    private func start(_ job: Job) {
        activeJobs += 1
        peakActiveJobs = max(peakActiveJobs, activeJobs)

        // This detached task is an intentional executor boundary: the pool
        // actor owns admission state, while connection setup and every
        // nonisolated segment of the operation must not inherit that actor.
        // The operation is async/non-blocking, so this creates a bounded task
        // count rather than a thread per connection.
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await job.operation()
            await self?.finish(jobID: job.id)
        }
        runningTasks[job.id] = task
    }

    private func finish(jobID: UInt64) {
        runningTasks.removeValue(forKey: jobID)
        activeJobs = max(0, activeJobs - 1)
        guard !stopped, activeJobs < maximumConcurrentJobs else { return }
        guard !pendingJobs.isEmpty else { return }
        let next = pendingJobs.removeFirst()
        start(next)
    }
}
