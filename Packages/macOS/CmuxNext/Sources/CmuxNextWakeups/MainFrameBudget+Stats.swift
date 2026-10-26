import Foundation

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
        /// Per class: tasks that started past the class's own share, on frame time the other classes
        /// left while no input was pending.
        public var idleTasks: [Int] = [0, 0, 0]
        /// Per class: tasks that ran past the class's whole budget on their own.
        public var overBudgetTasks: [Int] = [0, 0, 0]
        /// Per class: the longest task, in nanoseconds.
        public var maxTaskNanos: [UInt64] = [0, 0, 0]
        /// Per class: the most a class spent in one frame, in nanoseconds.
        public var maxFrameNanos: [UInt64] = [0, 0, 0]
        /// Pending-input checks that asked the input source, and the longest one in nanoseconds
        /// (the window server query's own main-thread cost).
        public var inputChecks = 0
        /// The longest pending-input check, in nanoseconds.
        public var maxInputCheckNanos: UInt64 = 0
        /// Render passes measured (the main run loop's before-waiting phase: layout, display and the
        /// Core Animation commit), and the longest in nanoseconds: what the scheduled work's changes
        /// cost after it, charged to the next frame (``MainFrameBudget/noteRenderPass(nanos:)``).
        public var renderPasses = 0
        /// The longest render pass measured, in nanoseconds.
        public var maxRenderPassNanos: UInt64 = 0
        /// Per class: times a task was held for the next frame because an input response was open
        /// (``MainFrameBudget/noteDiscreteInput(expectsFrame:)``).
        public var yieldedToInputResponse: [Int] = [0, 0, 0]
        /// Per class: times a task was held for the next frame because the typing burst allows one
        /// task per 100 ms and the class's last one started less than that ago.
        public var waitedForBurstSlot: [Int] = [0, 0, 0]
        /// Input responses that reached the 100 ms cap before a link tick rendered.
        public var inputResponseCapHits = 0
        /// The longest input response, in nanoseconds (from the input to what closed it).
        public var maxInputResponseNanos: UInt64 = 0
    }

    /// `workClass`'s slot in the per-class counters (``MainWorkClass/budgeted`` order); nil for the
    /// unbudgeted classes.
    static func index(_ workClass: MainWorkClass) -> Int? {
        switch workClass {
        case .input, .frame: nil
        case .visible: 0
        case .automation: 1
        case .background: 2
        }
    }

    /// `nanos` as milliseconds with two decimals (signpost messages).
    static func milliseconds(_ nanos: UInt64) -> String {
        String(format: "%.2f", Double(nanos) / 1_000_000)
    }
}
