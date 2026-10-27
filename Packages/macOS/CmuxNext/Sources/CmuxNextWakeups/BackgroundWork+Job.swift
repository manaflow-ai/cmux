// swift-atomics: shouldYield is inlinable, so the file names Compat's Atomic and its `Bool: AtomicValue`
// conformance publicly (as CmuxNextTrace's TraceRuntime).
public import Atomics
public import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

/// What one run of a yieldable job's body did (``BackgroundWork/job(_:shutdown:state:fileID:line:_:)``).
public enum JobStep<T: Sendable>: Sendable {
    /// The body saw ``JobDelegate/shouldYield`` and stopped between two chunks; the rest runs later from the
    /// state it left.
    case yielded
    /// The work is done; the job returns this.
    case finished(T)
}

/// What a running yieldable job reads between two chunks: Chrome's `JobDelegate` (base/task/post_job.h).
///
/// The lane sets ``shouldYield`` when an item above ``WorkPriority/bestEffort`` waits for a slot that this job
/// holds at a lower level, when the job's caller is cancelled, and when shutdown starts for a
/// ``ShutdownBehavior/skipOnShutdown`` job. Reading it is one relaxed atomic load.
public final class JobDelegate: Sendable {
    /// Set by the lane under its lock; read by the job's chunks.
    @usableFromInline let yieldAsked = Atomic<Bool>(false)
    /// Set once, by the caller's cancellation; never cleared.
    private let cancelled = Atomic<Bool>(false)

    init() {}

    /// Whether the job should stop after its current chunk and return ``JobStep/yielded``. Read it after each
    /// chunk, never before the first one of a run, so every run makes progress.
    @inlinable public var shouldYield: Bool {
        yieldAsked.load(ordering: .relaxed)
    }

    /// The caller's task was cancelled: the job yields and its rest is never queued.
    var isCancelled: Bool {
        cancelled.load(ordering: .sequentiallyConsistent)
    }

    /// The lane asks the running job to stop at its next chunk.
    func askToYield() {
        yieldAsked.store(true, ordering: .relaxed)
    }

    /// Marks the job cancelled and asks it to yield.
    func cancel() {
        cancelled.store(true, ordering: .sequentiallyConsistent)
        yieldAsked.store(true, ordering: .sequentiallyConsistent)
    }

    /// A new run starts unasked, unless the job is cancelled. Clearing before reading `cancelled` means a cancel
    /// that comes in between still leaves the flag set.
    func rearm() {
        yieldAsked.store(false, ordering: .sequentiallyConsistent)
        if isCancelled { yieldAsked.store(true, ordering: .sequentiallyConsistent) }
    }
}

extension BackgroundWork {
    /// Runs CPU work cut into chunks on ``BlockingLane/cpu`` at `priority` (boosted to the caller's priority at the
    /// call), giving its slot to higher work between chunks, and returns its result: Chrome's `base::PostJob`
    /// (base/task/post_job.h) with one worker.
    ///
    /// `body` runs one chunk after another from `state` and returns ``JobStep/finished(_:)`` when done. After each
    /// chunk it reads ``JobDelegate/shouldYield``; when that is true it returns ``JobStep/yielded`` and the lane
    /// queues its rest in its old place, so a waiting user-blocking or user-visible item starts on the freed slot
    /// first and the job continues from `state` afterwards. A job never yields to best-effort or idle work.
    ///
    /// ```swift
    /// let index = try await work.job(.bestEffort, state: IndexBuild(files)) { build, delegate in
    ///     repeat {
    ///         guard let file = build.next() else { return .finished(build.index) }
    ///         build.add(file)
    ///     } while !delegate.shouldYield
    ///     return .yielded
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - priority: how much a person waits for it; each run is at the higher of this and the caller's.
    ///   - shutdown: what ``shutdown()`` does with it. Only a ``ShutdownBehavior/blockShutdown`` job runs on to its
    ///     end after shutdown starts (and ``shutdown()`` waits for it). Any other job's rest never runs again: a
    ///     queued rest is dropped and a later yield is refused, so the caller gets `CancellationError`, as Chrome's
    ///     `TaskTracker::BeforeRunTask` refuses later runs of a non-block job. A running
    ///     ``ShutdownBehavior/skipOnShutdown`` run is asked to yield; a continue-on-shutdown run is not, so it ends
    ///     the job when that run finishes it.
    ///   - state: where the work starts; each run gets what the previous one left.
    ///   - fileID: the caller's `#fileID`, which names a slow block-shutdown run (leave the default).
    ///   - line: the caller's `#line`.
    ///   - body: one run: chunks of CPU work until it is done or ``JobDelegate/shouldYield``. It runs on a slot of
    ///     the cpu lane and must not block.
    /// - Returns: the value of ``JobStep/finished(_:)``.
    /// - Throws: what `body` throws; `CancellationError` when the caller's task is cancelled (the rest of the job
    ///   never runs) or shutdown dropped or refused its rest.
    public func job<State: Sendable, T: Sendable>(_ priority: WorkPriority, shutdown: ShutdownBehavior = .skipOnShutdown,
                                                  state: State, fileID: StaticString = #fileID, line: UInt = #line,
                                                  _ body: @escaping @Sendable (inout State, JobDelegate) throws -> JobStep<T>)
        async throws -> T {
        try Task.checkCancellation()
        let id = nextID()
        let delegate = JobDelegate()
        let scheduler = lanes[BlockingLane.cpu.rawValue]
        return try await withTaskCancellationHandler {
            try await withOnceThrowingContinuation { (continuation: OnceContinuation<T, any Error>) in
                let job = YieldableJob(id: id, priority: max(priority, WorkPriority(Task.currentPriority)), shutdown: shutdown,
                                       site: CallSite(fileID: fileID, line: line), delegate: delegate, body: body,
                                       continuation: continuation)
                queueRun(job, from: state, first: true)
            }
        } onCancel: {
            // Before the remove: a run that yields after it sees the flag under the lane's lock and is refused.
            delegate.cancel()
            scheduler.remove(id)?.abandon()
        }
    }

    /// One yieldable job: what each of its runs needs. Every run is a lane item with the job's id.
    private struct YieldableJob<State: Sendable, T: Sendable>: Sendable {
        let id: UInt64
        let priority: WorkPriority
        let shutdown: ShutdownBehavior
        let site: CallSite
        let delegate: JobDelegate
        let body: @Sendable (inout State, JobDelegate) throws -> JobStep<T>
        let continuation: OnceContinuation<T, any Error>
    }

    /// Queues the next run of `job` from `state`: the first at submit, a later one from the lane thread of the run
    /// that yielded, before that run's item ends (so a block-shutdown job never drops out of the shutdown count).
    private func queueRun<State: Sendable, T: Sendable>(_ job: YieldableJob<State, T>, from state: State, first: Bool) {
        let scheduler = lanes[BlockingLane.cpu.rawValue]
        guard let item = makeJob(id: job.id, lane: .cpu, shutdown: job.shutdown, site: job.site,
                                 work: { [self] in runOnce(job, from: state) },
                                 abandoned: { job.continuation.resume(throwing: CancellationError()) }) else {
            job.continuation.resume(throwing: CancellationError())
            return
        }
        let delegate = job.delegate
        let result = first
            ? scheduler.submit(item, at: job.priority, posted: false, delegate: delegate,
                               unless: { Task.isCancelled || delegate.isCancelled })
            : scheduler.requeue(item, at: job.priority, delegate: delegate, unless: { delegate.isCancelled })
        submitted(result, item, on: .cpu)
    }

    /// One run of `job` on its lane slot: finishes the job, or queues its rest when it yielded.
    private func runOnce<State: Sendable, T: Sendable>(_ job: YieldableJob<State, T>, from state: State) {
        var state = state
        do {
            switch try job.body(&state, job.delegate) {
            case .finished(let value): job.continuation.resume(returning: value)
            case .yielded: queueRun(job, from: state, first: false)
            }
        } catch {
            job.continuation.resume(throwing: error)
        }
    }
}
