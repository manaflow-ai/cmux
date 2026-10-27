import CmuxNextWakeups
import CmuxScreenKit

/// The stats line's next sample (``ScreenDeadline``) on a visible-class ``MainDeadline`` named `MacScreen.stats`:
/// it waits behind input, shares the main thread's one wake-up queue under the app's Energy Saver alignment, and
/// each fire is in the ledger.
@MainActor
final class MacScreenStatsDeadline: ScreenDeadline {
    static let owner = "MacScreen.stats"
    let deadline: MainDeadline

    init(scheduler: MainDeadlineScheduler) {
        deadline = MainDeadline(owner: Self.owner, workClass: .visible, scheduler: scheduler)
    }

    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {
        deadline.schedule(after: .seconds(max(0, seconds)), action)
    }

    func cancel() { deadline.cancel() }

    var isPending: Bool { deadline.isScheduled }
}
