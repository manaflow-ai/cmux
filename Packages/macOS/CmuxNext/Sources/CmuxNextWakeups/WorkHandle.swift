import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

/// One lane item from ``BackgroundWork/runHandle(_:mayBlock:shutdown:fileID:line:_:)``: its result, and the
/// raise that a later waiter gives it.
///
/// A raise moves a queued item to the higher priority's list, in post order, so it starts before the lower
/// items queued with it; a running item gets an override of its slot thread at the higher QoS
/// (`pthread_override_qos_class_start_np`), ended when the item finishes. Chrome's
/// `UpdateableSequencedTaskRunner::UpdatePriority` (base/task/updateable_sequenced_task_runner.h) and
/// `ScopedBoostablePriority` (base/threading/scoped_thread_priority.h). A raise never lowers an item.
public final class WorkHandle<T: Sendable>: Sendable {
    private enum Outcome {
        case pending([OnceContinuation<T, any Error>])
        case done(Result<T, any Error>)
    }

    private let id: UInt64
    private let scheduler: LaneScheduler
    // concurrency-allow: a one-shot result and its waiters, set once by the lane thread and read by awaiters; no I/O or wait under it (lock carve-out).
    private let outcome = Mutex(Outcome.pending([]))

    init(id: UInt64, scheduler: LaneScheduler) {
        self.id = id
        self.scheduler = scheduler
    }

    /// Runs the item at `priority` from now on when that is above its current priority; an equal or lower
    /// priority, or an item that finished, changes nothing. Never waits: one short lock and, for a running
    /// item, one kernel call.
    public func raise(to priority: WorkPriority) {
        scheduler.raise(id, to: priority, awaited: false)
    }

    /// The item's result. Awaiting it raises the item to the awaiter's priority (`Task.currentPriority`; main
    /// is ``WorkPriority/userBlocking``) and frees it from a best-effort fence, as for any awaited item.
    /// Cancelling the awaiting task does not cancel the item: ``cancel()`` does.
    ///
    /// - Throws: what the body threw, or `CancellationError` when the item was cancelled, dropped by shutdown or
    ///   refused before it ran.
    public var value: T {
        get async throws {
            scheduler.raise(id, to: WorkPriority(Task.currentPriority), awaited: true)
            return try await withOnceThrowingContinuation { (continuation: OnceContinuation<T, any Error>) in
                let ready = outcome.withLock { outcome -> Result<T, any Error>? in
                    switch outcome {
                    case .done(let result):
                        return result
                    case .pending(var waiters):
                        waiters.append(continuation)
                        outcome = .pending(waiters)
                        return nil
                    }
                }
                if let ready { continuation.resume(with: ready) }
            }
        }
    }

    /// Takes the item out of its queue when it has not started; ``value`` then throws `CancellationError`.
    /// A started item runs to its end.
    public func cancel() {
        scheduler.remove(id)?.abandon()
    }

    /// Stores the item's result and resumes every awaiter; the lane job calls it exactly once.
    func complete(_ result: Result<T, any Error>) {
        let waiters = outcome.withLock { outcome -> [OnceContinuation<T, any Error>] in
            guard case .pending(let waiters) = outcome else { return [] }
            outcome = .done(result)
            return waiters
        }
        for waiter in waiters { waiter.resume(with: result) }
    }
}
