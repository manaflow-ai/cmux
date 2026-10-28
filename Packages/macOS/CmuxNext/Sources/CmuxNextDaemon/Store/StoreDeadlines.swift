import CmuxNextWakeups

/// Where a store's main-thread deadlines go (the resync retry, a script batch's stage bound, a young command's
/// recheck): ``MainDeadline``s on the app's one ``MainDeadlineScheduler``, so each wakes with every other
/// main-thread deadline and posts its action in its class (p06-scheduler.md section E, recipe R-timer; Chromium's
/// `base::OneShotTimer` on a typed task runner, base/timer/timer.h).
///
/// `DaemonService` passes the app's scheduler. A store made without one (tests, fixtures) makes its own at its first
/// deadline, so a store that never schedules one builds no main-thread scheduler.
@MainActor
final class StoreDeadlines {
    private let injected: MainDeadlineScheduler?
    private var own: MainDeadlineScheduler?

    init(_ injected: MainDeadlineScheduler?) {
        self.injected = injected
    }

    /// The scheduler the store's deadlines are made on.
    var scheduler: MainDeadlineScheduler {
        if let injected { return injected }
        if let own { return own }
        let made = MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget()))
        own = made
        return made
    }

    /// A one-shot deadline of `owner` in `workClass` (flexible: a person or a request may wait on it, p06 rule 6).
    func deadline(owner: String, workClass: BudgetedWorkClass, file: StaticString = #fileID, line: UInt = #line) -> MainDeadline {
        MainDeadline(owner: owner, workClass: workClass, scheduler: scheduler, file: file, line: line)
    }
}
