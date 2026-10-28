public import CmuxNextWakeups

extension MainDeadlineScheduler {
    /// A deadline scheduler on a main-thread scheduler and wake-up queue of its own, for a test: the app passes its one
    /// (`AppServices.mainDeadlines`), and an owner's init has no default that makes one (sequence-manager-DESIGN.md S1).
    ///
    /// ```swift
    /// let host = WebUIHost(chromium: nil, openPanel: nil, memory: QuietMemoryRegistry(), deadlines: .testing())
    /// ```
    public static func testing() -> MainDeadlineScheduler {
        MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget()))
    }
}
