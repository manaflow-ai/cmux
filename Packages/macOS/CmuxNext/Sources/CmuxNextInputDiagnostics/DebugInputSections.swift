// The JSON shapes of the `debug.input` sections whose fields p04-input.md task 007 fixes: the main-thread
// job gate (DC2, DC10), the CEF pump's input policy (DC2) and the input tap. Their producers (tasks 021,
// 076, 024) fill them; the latency section is CmuxNextInputCore's InputLatencySnapshot.

/// `debug.input` section `gate`: the main-thread job gate (p04-input.md tasks 021, 076; DC2, DC10).
public nonisolated struct DebugInputGate: Sendable, Equatable, Codable {
    /// Jobs held while input was pending or dispatching, by where they were enqueued. The keys are
    /// `main` and `offMain`, the names p04-input.md task 007 and DC10 fix.
    public nonisolated struct HeldByOrigin: Sendable, Equatable, Codable {
        /// Enqueued on the main thread.
        public var main: UInt64
        /// Enqueued on another thread.
        public var offMain: UInt64

        public init(main: UInt64, offMain: UInt64) {
            self.main = main
            self.offMain = offMain
        }
    }

    public var heldByOrigin: HeldByOrigin
    /// Jobs passed through while input was pending, by the rule that exempted them (`input_dispatch`,
    /// `main_work_input`, `main_work_frame`).
    public var exemptByRule: [String: UInt64]
    /// The longest an input event waited behind main-thread jobs.
    public var maxInputWaitBehindJobsMilliseconds: Double
    /// Held jobs that ran more than one refresh after they were enqueued.
    public var jobsDeferredOverOneFrame: UInt64
    /// Non-Swift main-thread work (GCD main blocks, run-loop sources, timers) that ran while input was
    /// pending.
    public var nonswiftBlocksWhileInputPending: UInt64

    public init(heldByOrigin: HeldByOrigin, exemptByRule: [String: UInt64], maxInputWaitBehindJobsMilliseconds: Double,
                jobsDeferredOverOneFrame: UInt64, nonswiftBlocksWhileInputPending: UInt64) {
        self.heldByOrigin = heldByOrigin
        self.exemptByRule = exemptByRule
        self.maxInputWaitBehindJobsMilliseconds = maxInputWaitBehindJobsMilliseconds
        self.jobsDeferredOverOneFrame = jobsDeferredOverOneFrame
        self.nonswiftBlocksWhileInputPending = nonswiftBlocksWhileInputPending
    }

    private enum CodingKeys: String, CodingKey {
        case heldByOrigin = "held_by_origin"
        case exemptByRule = "exempt_by_rule"
        case maxInputWaitBehindJobsMilliseconds = "max_input_wait_behind_jobs_ms"
        case jobsDeferredOverOneFrame = "jobs_deferred_over_one_frame"
        case nonswiftBlocksWhileInputPending = "nonswift_blocks_while_input_pending"
    }
}

/// `debug.input` section `pump`: the CEF message pump's input policy (p04-input.md task 024; DC2).
public nonisolated struct DebugInputPump: Sendable, Equatable, Codable {
    /// Pump passes that ran while input was pending, by the input's target (`terminal`, `chromiumPage`, ...).
    /// For a non-Chromium target it should stay 0.
    public var passesWhileInputPending: [String: UInt64]
    /// Passes the policy put off until the input's dispatch ended.
    public var deferredForInput: UInt64
    /// One pass's main-thread time, 99th percentile.
    public var passMillisecondsP99: Double

    public init(passesWhileInputPending: [String: UInt64], deferredForInput: UInt64, passMillisecondsP99: Double) {
        self.passesWhileInputPending = passesWhileInputPending
        self.deferredForInput = deferredForInput
        self.passMillisecondsP99 = passMillisecondsP99
    }

    private enum CodingKeys: String, CodingKey {
        case passesWhileInputPending = "passes_while_input_pending"
        case deferredForInput = "deferred_for_input"
        case passMillisecondsP99 = "pass_ms_p99"
    }
}

/// `debug.input` section `tap`: the one input tap's live subscriptions (p04-input.md task 011).
public nonisolated struct DebugInputTap: Sendable, Equatable, Codable {
    /// The live subscriptions of one event class, per delivery stage.
    public nonisolated struct Subscribers: Sendable, Equatable, Codable {
        /// ``InputEventClass`` case name.
        public var eventClass: String
        public var observe: Int
        public var intercept: Int
        public var afterDispatch: Int

        public init(eventClass: String, observe: Int, intercept: Int, afterDispatch: Int) {
            self.eventClass = eventClass
            self.observe = observe
            self.intercept = intercept
            self.afterDispatch = afterDispatch
        }

        private enum CodingKeys: String, CodingKey {
            case eventClass = "class"
            case observe, intercept
            case afterDispatch = "after_dispatch"
        }
    }

    /// One row per event class, in ``InputEventClass`` order.
    public var subscribers: [Subscribers]
    /// Other-app monitors (`globalObserve`) installed now.
    public var globalMonitors: Int
    /// The owner-set flags on now (`hints_showing`, `find_pill_open`).
    public var flags: [String]
    /// The ``InputEventType`` case name of the last event the app dispatched; nil before the first.
    public var lastDispatched: String?

    public init(subscribers: [Subscribers], globalMonitors: Int, flags: [String], lastDispatched: String?) {
        self.subscribers = subscribers
        self.globalMonitors = globalMonitors
        self.flags = flags
        self.lastDispatched = lastDispatched
    }

    private enum CodingKeys: String, CodingKey {
        case subscribers
        case globalMonitors = "global_monitors"
        case flags
        case lastDispatched = "last_dispatched"
    }
}
