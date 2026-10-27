import CmuxNextWakeups
import MessagesLabHome

/// The MessagesLab controller's engine-clock wake-ups (scheduled actions, cleanups, settles) as one
/// `visible` ``MainDeadline`` of the transcript (p06-scheduler.md, recipe R-timer): no sleep, no
/// polling. Each fire waits behind the person's input in the main-thread scheduler, and while the
/// transcript is hidden its wakes align to the second, as Blink aligns a hidden page's timers
/// (`kDefaultThrottledWakeUpInterval`, third_party/blink/renderer/platform/scheduler/main_thread/page_scheduler_impl.h).
/// Nobody waits on a hidden transcript's engine clock: it only moves rows and settles motion.
final class HomeDemandWake: ChatWakeScheduler {
    let deadline: MainDeadline
    /// The app's deadline scheduler: the views' deadlines (``makeDeadline(owner:exact:)``) are its entries.
    private let deadlines: MainDeadlineScheduler

    /// - Parameters:
    ///   - node: the transcript's visibility node: its wakes align while it is hidden.
    ///   - deadlines: the app's one deadline placer (`AppServices.mainDeadlines`).
    init(node: VisibilityNode, deadlines: MainDeadlineScheduler) {
        self.deadlines = deadlines
        deadline = MainDeadline(owner: "Home.transcript.wake", workClass: .visible, alignment: .whenHidden(node),
                                scheduler: deadlines)
    }

    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {
        deadline.schedule(after: .seconds(max(0, seconds)), action)
    }

    func cancel() { deadline.cancel() }

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
