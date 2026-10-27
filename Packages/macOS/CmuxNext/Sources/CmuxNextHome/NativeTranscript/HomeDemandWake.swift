import CmuxNextWakeups
import MessagesLabHome

/// The MessagesLab controller's engine-clock wake-ups on CmuxNext's one-shot
/// timer (no sleep, no polling; each fire is recorded in the wakeup ledger).
final class HomeDemandWake: ChatWakeScheduler {
    private let timer = DemandTimer(owner: "Home.transcript.wake")
    /// The app's deadline scheduler: the views' deadlines (``makeDeadline(owner:exact:)``) are its entries.
    private let deadlines: MainDeadlineScheduler

    init(deadlines: MainDeadlineScheduler) {
        self.deadlines = deadlines
    }

    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {
        timer.scheduleOnMain(after: .seconds(max(0, seconds)), action)
    }

    func cancel() { timer.cancel() }

    /// A visible-class ``MainDeadline``: the scroller's show, widen and hide wait behind input, share the main
    /// thread's one wake-up queue under the app's Energy Saver alignment, and each fire is in the ledger.
    func makeDeadline(owner: String, exact: Bool) -> any ViewDeadline {
        HomeViewDeadline(MainDeadline(owner: owner, workClass: .visible, alignment: exact ? .precise : .flexible,
                                      scheduler: deadlines))
    }
}

/// One view deadline of the transcript (``ViewDeadline``) on a ``MainDeadline``.
final class HomeViewDeadline: ViewDeadline {
    let deadline: MainDeadline

    init(_ deadline: MainDeadline) {
        self.deadline = deadline
    }

    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {
        deadline.schedule(after: .seconds(max(0, seconds)), action)
    }

    func cancel() { deadline.cancel() }

    var isPending: Bool { deadline.isScheduled }
}
