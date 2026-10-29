public import CmuxNextWakeups
import Foundation

/// Runs main-actor work at most once per display frame. The App injects a
/// display-link-backed scheduler (`DaemonService.drainScheduler`), which
/// coalesces every event that arrived in between into one drain.
public protocol FrameBatchScheduler: Sendable {
    func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void)
}

/// Runs the drain's tail (``DrainTail``): the daemon transactions after the last
/// one a person or the app's frontend caused, one budgeted task at a time, in the class of the
/// cause at the tail's head. The app passes its ``MainWorkScheduler``
/// (``DaemonStore/drainTailScheduler``); a store with none applies every batch whole in its frame.
@MainActor
public protocol DrainTailScheduler: AnyObject {
    /// Queues `body` in `workClass`, after the work queued before it in that class; never inline.
    func postDrainTail(_ workClass: BudgetedWorkClass, _ body: @escaping @MainActor () -> Void)
    /// Whether the running task of `workClass` may go on with one more transaction: its class
    /// share is left and no input of the person waits (``MainFrameBudget/mayRun(_:)``).
    func drainTailMayContinue(_ workClass: BudgetedWorkClass) -> Bool
}

extension MainWorkScheduler: DrainTailScheduler {
    public func postDrainTail(_ workClass: BudgetedWorkClass, _ body: @escaping @MainActor () -> Void) {
        post(workClass, owner: "DaemonStore.drainTail", body)
    }

    public func drainTailMayContinue(_ workClass: BudgetedWorkClass) -> Bool {
        budget.mayRun(workClass.workClass)
    }
}
