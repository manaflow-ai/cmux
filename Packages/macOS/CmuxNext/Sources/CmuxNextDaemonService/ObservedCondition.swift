public import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// One wait on the main actor until a condition over observable state holds
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, recipe R-wait): a `ServiceObservation` reads the
/// condition again only when something it read changed, at most once per frame, as a task with a class
/// and an owner; an optional `MainDeadline` bounds the wait. Chromium waits the same way: an observer
/// that signals once plus a `base::OneShotTimer` for the bound (`base/one_shot_event.h`,
/// `base/timer/timer.h`), never a loop that re-reads.
///
/// A wait for a record the daemon store keys uses `StoreWaiters` instead (`DaemonStore.waitForTab` and the
/// others); this type is for conditions no store key names (a workspace's first tab, a room in the
/// personal projection).
///
/// ```swift
/// await ObservedCondition(owner: "FirstTabHold.firstTab", .visible, on: mainWork)
///     .until(timeout: .seconds(2), deadlines: mainDeadlines) { store.hasTab(id) }
/// ```
@MainActor
public final class ObservedCondition {
    private let owner: String
    private let workClass: BudgetedWorkClass
    private let work: MainWorkScheduler
    private var continuation: OnceContinuation<Void, OnceContinuationError>?
    private var watch: ServiceObservation<Bool>?
    private var limit: MainDeadline?
    private var ended = false

    /// - Parameters:
    ///   - owner: The wait's name on the scheduler's board and in the wakeup ledger.
    ///   - workClass: The class its re-reads and its timeout run in.
    ///   - work: The app's one main-thread scheduler.
    public init(owner: String, _ workClass: BudgetedWorkClass, on work: MainWorkScheduler) {
        self.owner = owner
        self.workClass = workClass
        self.work = work
    }

    /// A caller is suspended in ``until(timeout:deadlines:_:)`` (tests).
    public var isWaiting: Bool { continuation != nil }

    /// Returns once `condition` holds (at once when it holds now), after `timeout` on `deadlines` when both
    /// are given, or when the calling task is cancelled. One use: a second call returns at once.
    public func until(timeout: Duration? = nil, deadlines: MainDeadlineScheduler? = nil,
                      _ condition: @escaping @MainActor () -> Bool) async {
        guard !ended, !condition() else { return end() }
        let work = work, owner = owner
        await withTaskCancellationHandler {
            // A dropped wait returns as an ended one does.
            _ = try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
                self.continuation = continuation
                guard !Task.isCancelled else { return end() }
                if let timeout, let deadlines {
                    let limit = MainDeadline(owner: owner, workClass: workClass, scheduler: deadlines)
                    self.limit = limit
                    limit.schedule(after: timeout) { [weak self] in self?.end() }
                }
                let watch = ServiceObservation(workClass, owner: owner, on: work, read: condition) { [weak self] holds in
                    if holds { self?.end() }
                }
                // The first read applies inside the init: a condition that turned true in between ended the wait.
                if ended { watch.cancel() } else { self.watch = watch }
            }
        } onCancel: { [weak self] in
            work.postFromAnyThread(.visible, owner: owner) { [weak self] in self?.end() }
        }
    }

    private func end() {
        guard !ended else { return }
        ended = true
        limit?.cancel()
        limit = nil
        watch?.cancel()
        watch = nil
        continuation?.resume(returning: ())
        continuation = nil
    }
}
