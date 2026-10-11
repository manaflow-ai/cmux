public import Dispatch

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
///
/// Pending jobs carry their submission time. When `maximumPendingAgeNanoseconds`
/// is set, a job that waited longer than that for a slot is dropped (through
/// its cleanup, with ``DropReason/pendingExpired``) instead of started: its
/// client has already given up, and running the command late would only apply
/// stale side effects. Expiry is evaluated whenever a slot frees or the queue
/// is full, so no timer is needed and a stalled pool drains as soon as any
/// slot moves.
public actor ControlClientWorkerPool {
    /// Why a pending job was handed to its cleanup instead of started.
    public enum DropReason: Sendable, Equatable {
        /// The pending queue was full when the job was submitted.
        case pendingQueueFull
        /// The job waited longer than `maximumPendingAgeNanoseconds`.
        case pendingExpired
        /// The pool stopped while the job was pending or being submitted.
        case stopped
    }

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
        /// Number of pending jobs dropped for exceeding the maximum pending age.
        public let expiredJobs: Int
        /// Whether no further jobs can be admitted.
        public let isStopped: Bool

        /// Creates a metrics snapshot.
        public init(
            activeJobs: Int,
            pendingJobs: Int,
            peakActiveJobs: Int,
            rejectedJobs: Int,
            expiredJobs: Int = 0,
            isStopped: Bool
        ) {
            self.activeJobs = activeJobs
            self.pendingJobs = pendingJobs
            self.peakActiveJobs = peakActiveJobs
            self.rejectedJobs = rejectedJobs
            self.expiredJobs = expiredJobs
            self.isStopped = isStopped
        }
    }

    private struct Job {
        let id: UInt64
        let submittedAtNanoseconds: UInt64
        let operation: @Sendable () async -> Void
        let onDrop: @Sendable (DropReason) -> Void
    }

    private let maximumConcurrentJobs: Int
    private let maximumPendingJobs: Int
    private let maximumPendingAgeNanoseconds: UInt64?
    private let now: @Sendable () -> UInt64
    private var activeJobs = 0
    private var peakActiveJobs = 0
    private var rejectedJobs = 0
    private var expiredJobs = 0
    private var nextJobID: UInt64 = 1
    private var pendingJobs: [Job] = []
    private var runningTasks: [UInt64: Task<Void, Never>] = [:]
    private var stopped = false

    /// Creates a bounded pool.
    ///
    /// - Parameters:
    ///   - maximumConcurrentJobs: Upper bound on live connection operations.
    ///   - maximumPendingJobs: Upper bound on FIFO jobs waiting for a slot.
    ///   - maximumPendingAgeNanoseconds: Longest a job may wait for a slot
    ///     before it is dropped instead of started; `nil` never expires.
    ///   - now: Monotonic clock for submission stamps and expiry checks.
    ///     Tests inject a virtual clock.
    ///
    /// Values are clamped to preserve a useful, finite admission policy even
    /// when a caller forwards an invalid configuration value.
    public init(
        maximumConcurrentJobs: Int = 32,
        maximumPendingJobs: Int = 64,
        maximumPendingAgeNanoseconds: UInt64? = nil,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.maximumConcurrentJobs = max(1, maximumConcurrentJobs)
        self.maximumPendingJobs = max(0, maximumPendingJobs)
        self.maximumPendingAgeNanoseconds = maximumPendingAgeNanoseconds
        self.now = now
    }

    /// Attempts to submit one asynchronous connection operation.
    ///
    /// - Parameter operation: The operation that owns its admitted connection
    ///   until it returns. It must be cancellation-aware when it waits for
    ///   external I/O.
    /// - Parameter onDrop: Synchronous cleanup for a rejected, expired, or
    ///   stopped pending operation (typically answering and closing its
    ///   descriptor), told why it was dropped.
    /// - Returns: Whether the operation started, queued, or was rejected.
    public func submit(
        _ operation: @escaping @Sendable () async -> Void,
        onDrop: @escaping @Sendable (DropReason) -> Void = { _ in }
    ) -> Submission {
        guard !stopped else {
            rejectedJobs += 1
            onDrop(.stopped)
            return .rejected
        }

        let job = Job(
            id: nextJobID,
            submittedAtNanoseconds: now(),
            operation: operation,
            onDrop: onDrop
        )
        nextJobID &+= 1
        if activeJobs < maximumConcurrentJobs {
            start(job)
            return .started
        }
        if pendingJobs.count >= maximumPendingJobs {
            dropExpiredPendingJobs(at: job.submittedAtNanoseconds)
        }
        guard pendingJobs.count < maximumPendingJobs else {
            rejectedJobs += 1
            onDrop(.pendingQueueFull)
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
            job.onDrop(.stopped)
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
            expiredJobs: expiredJobs,
            isStopped: stopped
        )
    }

    /// Hands every pending job older than the maximum pending age to its
    /// cleanup. Evaluated at admission decisions only, so a stalled pool
    /// drains the moment a slot moves without any timer.
    private func dropExpiredPendingJobs(at nowNanoseconds: UInt64) {
        guard let maximumPendingAgeNanoseconds, !pendingJobs.isEmpty else { return }
        let expired = pendingJobs.filter { job in
            nowNanoseconds &- job.submittedAtNanoseconds > maximumPendingAgeNanoseconds
        }
        guard !expired.isEmpty else { return }
        let expiredIDs = Set(expired.map(\.id))
        pendingJobs.removeAll { expiredIDs.contains($0.id) }
        expiredJobs += expired.count
        for job in expired {
            job.onDrop(.pendingExpired)
        }
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
        dropExpiredPendingJobs(at: now())
        guard !pendingJobs.isEmpty else { return }
        let next = pendingJobs.removeFirst()
        start(next)
    }
}
