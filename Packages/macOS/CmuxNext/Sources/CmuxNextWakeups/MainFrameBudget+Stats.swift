extension MainFrameBudget {
    /// Counters for `debug.main_budget` and the benches.
    public struct Stats: Sendable, Equatable {
        /// Frames the budget saw (display ticks plus windows rolled by a task outside any tick).
        public var frames = 0
        /// Per budgeted class (``MainWorkClass/budgeted`` order): tasks run.
        public var tasks: [Int] = [0, 0, 0]
        /// Per class: times a task was held for the next frame because input was pending.
        public var yieldedToInput: [Int] = [0, 0, 0]
        /// Per class: times a task was held for the next frame because the class's budget was spent.
        public var deferredOverBudget: [Int] = [0, 0, 0]
        /// Per class: tasks that ran past the class's whole budget on their own.
        public var overBudgetTasks: [Int] = [0, 0, 0]
        /// Per class: the longest task, in nanoseconds.
        public var maxTaskNanos: [UInt64] = [0, 0, 0]
        /// Per class: the most a class spent in one frame, in nanoseconds.
        public var maxFrameNanos: [UInt64] = [0, 0, 0]
        /// Pending-input checks that asked the input source, and the longest one in nanoseconds
        /// (the window server query's own main-thread cost).
        public var inputChecks = 0
        public var maxInputCheckNanos: UInt64 = 0
    }
}
