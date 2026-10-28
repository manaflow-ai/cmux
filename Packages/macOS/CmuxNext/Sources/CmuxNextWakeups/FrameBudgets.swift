/// Per-frame budgets of the budgeted classes (``MainFrameBudget/Budgets``).
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
///
/// The shares are written for 60 Hz. Under the after-commit placement (``BudgetedBatchPlacement``)
/// they scale with the refresh period (``scaled(toIntervalNanos:)``) and the pass target is the
/// period less ``inputReserve`` and the measured render pass (``passTargetNanos(intervalNanos:renderNanos:)``).
public struct FrameBudgets: Sendable, Equatable {
    /// The share of screen updates no action of the person caused (2.5 ms by default).
    public var visible: Duration
    /// The share of work an agent, the CLI or another process asked for (1 ms by default).
    public var automation: Duration
    /// The share of work nobody waits on (0.5 ms by default).
    public var background: Duration

    /// Shares per class; the defaults split the 4 ms of scheduled work a frame may hold.
    public init(visible: Duration = .microseconds(2_500), automation: Duration = .milliseconds(1),
                background: Duration = .microseconds(500)) {
        self.visible = visible
        self.automation = automation
        self.background = background
    }

    /// The scheduled work one frame may hold in all (the sum of the shares): one main run loop
    /// pass stays under the 8 ms stall target with input dispatch and the commit. userBlocking
    /// work counts in it too.
    public var total: Duration { visible + automation + background }

    /// The cap of ``MainWorkClass/userBlocking``: the visible + automation shares
    /// (p06-scheduler.md, section 3A). It never runs past it on idle frame time, so a flood of it
    /// leaves the background share and the first task of every other class.
    public var userBlocking: Duration { visible + automation }

    /// The main run loop pass the budget protects under the in-tick placement: no main-thread stall
    /// over 8 ms (perf-lead.md section 1). The scheduled work of a frame plus the last render pass
    /// (layout, display, commit) stays under it: past 4 ms of render, the scheduled work gets less.
    public var passTarget: Duration = .milliseconds(8)

    /// The person's input dispatch a frame keeps free of scheduled work under the after-commit
    /// placement (``passTargetNanos(intervalNanos:renderNanos:)``).
    public var inputReserve: Duration = .milliseconds(2)

    /// The refresh period the shares are written for: 60 Hz.
    public static let referenceIntervalNanos: UInt64 = 16_666_667

    /// The budget of `workClass`; nil for the unbudgeted classes (idle work has a deadline per
    /// idle period instead, ``IdleDeadline``).
    public func budget(_ workClass: MainWorkClass) -> Duration? {
        switch workClass {
        case .input, .frame, .idle: nil
        case .userBlocking: userBlocking
        case .visible: visible
        case .automation: automation
        case .background: background
        }
    }

    /// The shares for a display whose refresh period is `intervalNanos`: each share times
    /// interval / 16.7 ms, so at 120 Hz visible gets 1.25 ms. A slower display keeps the 60 Hz
    /// shares: the turn target (p99 under 4 ms) does not grow with the period. ``passTarget`` and
    /// ``inputReserve`` are kept.
    public func scaled(toIntervalNanos intervalNanos: UInt64) -> FrameBudgets {
        guard intervalNanos > 0, intervalNanos < Self.referenceIntervalNanos else { return self }
        let interval = Int(intervalNanos), reference = Int(Self.referenceIntervalNanos)
        var scaled = self
        scaled.visible = visible * interval / reference
        scaled.automation = automation * interval / reference
        scaled.background = background * interval / reference
        return scaled
    }

    /// The scheduled work a frame of `intervalNanos` may hold after a render pass of `renderNanos`
    /// under the after-commit placement: the period less ``inputReserve`` and the render pass (zero
    /// when they fill it; each class's first task still runs).
    public func passTargetNanos(intervalNanos: UInt64, renderNanos: UInt64) -> UInt64 {
        let taken = MainFrameBudget.nanos(inputReserve) &+ renderNanos
        return intervalNanos > taken ? intervalNanos - taken : 0
    }
}

/// Where a frame's budgeted batch runs (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// "Budget mechanics"). The feature `mainBudgetTurn` picks it at the composition root.
public enum BudgetedBatchPlacement: Sendable, Equatable {
    /// Inside the display-link tick, after its frame-locked clients, on the fixed 60 Hz shares and
    /// the 8 ms pass target (``FrameBudgets/passTarget``): the path before p06-scheduler-201.
    case inTick
    /// In a main run-loop turn of its own, signaled once the tick's commit ran (``AfterFrameCommitTurn``),
    /// on refresh-scaled shares and the pass target interval - 2 ms - render, with a deadline of the
    /// next vsync less the commit estimate. A tick turn is then the drain, the frame clients and the
    /// render; a budget turn is at most the class shares and its own commit. Chrome's renderer main
    /// thread does the same split: the BeginMainFrame task is its own task, and the scheduler runs
    /// other queues' tasks between frames up to the next frame's deadline
    /// (third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc).
    case afterCommit
}

/// The after-commit placement's budget turns (``MainFrameBudget/beginBudgetTurn()``): how many ran,
/// how many ended their work past their deadline (the next vsync less the commit estimate), and the
/// furthest past it. A late turn is one whose first task alone ran past the deadline, or whose tick
/// came too late for any work.
public struct BudgetTurnStats: Sendable, Equatable {
    public var turns = 0
    public var pastDeadline = 0
    public var maxOverrunNanos: UInt64 = 0

    public init() {}

    /// One budget turn's work ended at `now`; `deadline` is its frame's (nil: none).
    mutating func noteEnded(at now: UInt64, deadline: UInt64?) {
        turns += 1
        guard let deadline, now > deadline else { return }
        pastDeadline += 1
        maxOverrunNanos = max(maxOverrunNanos, now - deadline)
    }
}
