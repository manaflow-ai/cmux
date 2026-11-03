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
    ///
    /// The 4 ms split assumes input plus commit fit in the other 4 ms; the commit is measured
    /// (``RenderPassMeter``) and a longer one lowers the next frame's scheduled work
    /// (``passTarget``), so a request whose commit is expensive pays for it.
    ///
    /// The shares hold while a person's input is pending. With none pending, a class may go past
    /// its share into the time the others left, up to ``total`` (``MainFrameBudget/mayRun(_:)``):
    /// a CLI storm on an otherwise idle main thread gets the whole 4 ms a frame, as the control
    /// work queue had before the split.
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

        /// The scheduled work one frame may hold in all (the sum of the shares): one main run loop
        /// pass stays under the 8 ms stall target with input dispatch and the commit.
        public var total: Duration { visible + automation + background }

        /// The main run loop pass the budget protects: no main-thread stall over 8 ms
        /// (perf-lead.md section 1). The scheduled work of a frame plus the last render pass (layout,
        /// display, commit) stays under it: past 4 ms of render, the scheduled work gets less.
        public var passTarget: Duration = .milliseconds(8)

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
