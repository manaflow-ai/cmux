/// What a repeating maintenance activity asks for (``BackgroundActivityScheduling``): how often, how
/// late the OS may run it, and how its main-actor intent is classed and attributed.
public struct BackgroundActivityRequest: Sendable, Equatable {
    /// The activity's reverse-DNS identifier (`NSBackgroundActivityScheduler(identifier:)`).
    public let identifier: String
    /// The intent's owner in the main task board and the wakeup ledger (an `allowed_periodic` owner
    /// of scripts/cmux-next/idle-budget.json).
    public let owner: String
    /// The nominal time between two runs.
    public let interval: Duration
    /// How far from the nominal time the OS may move a run, to batch it with other work.
    public let tolerance: Duration
    /// The class the intent is posted in on the main thread.
    public let workClass: BudgetedWorkClass

    public init(identifier: String, owner: String, interval: Duration, tolerance: Duration,
                workClass: BudgetedWorkClass = .background) {
        self.identifier = identifier
        self.owner = owner
        self.interval = interval
        self.tolerance = tolerance
        self.workClass = workClass
    }
}
