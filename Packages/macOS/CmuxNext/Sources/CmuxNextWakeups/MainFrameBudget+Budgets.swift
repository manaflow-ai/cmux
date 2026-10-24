extension MainFrameBudget {
    /// Per-frame budgets of the budgeted classes.
    ///
    /// The target is no main-thread stall over 8 ms (perf-lead.md section 1: key to frame p95
    /// under 8 ms). A frame's pass runs: the person's input dispatch (under 2 ms a key, PL-typing
    /// batch 1), the scheduled tasks, and the Core Animation commit of what they changed. The
    /// scheduled classes together get 4 ms, so input plus commit keep at least 4 ms of the 8:
    /// visible updates 2.5 ms (the store's batch and the row patches it causes), automation 1 ms
    /// (agent and CLI requests, below the person's own updates), background 0.5 ms. The previous
    /// control work queue's 4 ms budget for one class alone is the upper bound this splits.
    public struct Budgets: Sendable, Equatable {
        public var visible: Duration
        public var automation: Duration
        public var background: Duration

        public init(visible: Duration = .microseconds(2_500), automation: Duration = .milliseconds(1),
                    background: Duration = .microseconds(500)) {
            self.visible = visible
            self.automation = automation
            self.background = background
        }

        /// The budget of `workClass`; nil for the unbudgeted classes.
        public func budget(_ workClass: MainWorkClass) -> Duration? {
            switch workClass {
            case .input, .frame: nil
            case .visible: visible
            case .automation: automation
            case .background: background
            }
        }
    }
}
