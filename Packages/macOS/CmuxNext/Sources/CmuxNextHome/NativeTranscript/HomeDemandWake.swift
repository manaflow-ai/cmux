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

    /// - Parameters:
    ///   - node: the transcript's visibility node: its wakes align while it is hidden.
    ///   - deadlines: the app's one deadline placer (`AppServices.mainDeadlines`).
    init(node: VisibilityNode, deadlines: MainDeadlineScheduler) {
        deadline = MainDeadline(owner: "Home.transcript.wake", workClass: .visible, alignment: .whenHidden(node),
                                scheduler: deadlines)
    }

    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {
        deadline.schedule(after: .seconds(max(0, seconds)), action)
    }

    func cancel() { deadline.cancel() }
}
