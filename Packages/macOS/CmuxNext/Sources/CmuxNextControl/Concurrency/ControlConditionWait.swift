public import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// A control request's wait for a main-actor condition that no keyed waiter covers: a tab's page reaching the
/// cache after `cmux browser open` (cx-qncg), a hibernated tab coming back for an agent, a page with no keyed waits
/// ending its load (plans/cmux-next/chrome-parity/p06-scheduler.md, recipes R-obs and R-wait).
///
/// One ``ServiceObservation`` in the automation class follows the condition for the wait's life: the changes of a
/// turn reach it in one posted automation task, so a burst of changes behind an agent's wait never takes the
/// person's frame. Chromium waits on a condition the same way, from the change itself (`base/one_shot_event.h`,
/// `content::WebContentsObserver`), never from a poll.
///
/// The wait has no timer of its own: the request's ``ControlDeadline`` bounds it and cancels the waiting task.
///
/// ```swift
/// let present = await ControlConditionWait(on: mainWork, owner: "browser.page.await_page").until {
///     _ = cache.pageInstalls.revision
///     return cache.existingBrowser(tabID) != nil
/// }
/// ```
@MainActor
public final class ControlConditionWait {
    private let work: MainWorkScheduler
    private let owner: String
    private var continuation: OnceContinuation<Bool, OnceContinuationError>?
    private var observation: ServiceObservation<Bool>?

    /// One wait on `work`, named `owner` in the board and `debug.observations`.
    public init(on work: MainWorkScheduler, owner: String) {
        self.work = work
        self.owner = owner
    }

    /// True once `condition` holds: read now, then after each change of what it read; false when the waiting task
    /// is cancelled, or at once while another ``until(_:)`` of this wait is waiting.
    ///
    /// - Parameter condition: Read on the main actor with tracking.
    public func until(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        if condition() { return true }
        guard continuation == nil else { return false }
        let (work, owner) = (self.work, self.owner)
        return await withTaskCancellationHandler {
            // A wait whose continuation is dropped unresumed reads as not met, as a cancelled one does.
            (try? await withOnceContinuation { (continuation: OnceContinuation<Bool, OnceContinuationError>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                self.continuation = continuation
                // Its first apply runs inside the initializer: a wait that apply resumes keeps no observation.
                let observation = ServiceObservation(.automation, owner: owner, on: work, read: condition) { [weak self] met in
                    if met { self?.finish(true) }
                }
                if self.continuation == nil { observation.cancel() } else { self.observation = observation }
            }) ?? false
        } onCancel: {
            work.postFromAnyThread(.automation, owner: owner) { self.finish(false) }
        }
    }

    /// Resumes the waiter once and stops following the condition.
    private func finish(_ met: Bool) {
        observation?.cancel()
        observation = nil
        continuation?.resume(returning: met)
        continuation = nil
    }
}
