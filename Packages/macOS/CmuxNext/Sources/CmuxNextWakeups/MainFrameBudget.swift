public import Foundation
import CmuxNextSignposts
import Darwin

/// The one main-thread scheduler's per-frame budget (plans/cmux-next/main-thread-budget.md).
///
/// The main thread does input dispatch, the minimal mutation of visible state and the Core
/// Animation commit; everything else runs off it. What the app still schedules there runs as a
/// task of a ``MainWorkClass``. Frame-locked work (``MainWorkClass/frame``) and injected input run
/// unbudgeted. Each budgeted class (visible, automation, background) gets a per-frame budget, and
/// in priority order: a frame's visible updates run before its automation work, which runs before
/// background work. A budgeted class also yields while a person's input is pending
/// (``InputPendingSource``, or an injected key queued on ``MainTaskBoard``), so a key or a click
/// is dispatched before the batch, and the batch runs on the next frame.
///
/// Two rules keep every change on screen within one frame of being due:
/// - the first task of a class in a frame always fits its budget, so each class makes progress
///   every frame however long its tasks are;
/// - a class that yielded to input in one frame does not yield again in the next one (a person
///   typing at 30 keys a second never starves the sidebar).
///
/// This is batching to the display cadence, not a throttle: work over budget runs on the next
/// frame, never later. One instance serves the whole app (``FrameScheduler/app`` owns it, every
/// window scheduler shares it), so a frame's budget is the same however many display links tick.
///
/// ```swift
/// // A FrameBatcher drains its queued work one task at a time:
/// while let work = queue.first, budget.mayRun(.visible) {
///     budget.run(.visible, owner: "DaemonStore.drain") { work() }
/// }
/// ```
@MainActor
public final class MainFrameBudget {
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
    }

    /// The board the stall watchdog reads.
    public let board: MainTaskBoard
    public let budgets: Budgets
    public private(set) var stats = Stats()
    private let input: any InputPendingSource
    private let uptimeNanos: () -> UInt64
    private let signposts: Bool
    // Frame window.
    private var windowStart: UInt64 = 0
    private var windowLength: UInt64 = 16_666_667
    private var lastTimestamp: CFTimeInterval?
    private var spent: [UInt64] = [0, 0, 0]
    private var ranThisFrame: [Bool] = [false, false, false]
    private var yieldedLastFrame: [Bool] = [false, false, false]
    private var yieldedThisFrame: [Bool] = [false, false, false]
    private var sequence: UInt32 = 0
    private var open: [OpenTask] = []
    /// The input check's last answer and when (a frame asks several times; the answer is reused
    /// for a quarter millisecond).
    private var inputAnswer: (at: UInt64, pending: Bool) = (0, false)

    /// - Parameters:
    ///   - budgets: Per-class budgets (default: the measured split in ``Budgets``).
    ///   - input: The pending-input check (the app: ``SessionInputPending``; tests: a fake).
    ///   - board: Where the running task is published for the watchdog.
    ///   - signposts: Whether each task opens a `stall.main_task` interval (the app: true).
    ///   - uptimeNanos: The clock (`CLOCK_UPTIME_RAW` nanoseconds); tests inject one they move.
    public init(budgets: Budgets = Budgets(), input: any InputPendingSource = NoInputPending(), board: MainTaskBoard = MainTaskBoard(),
                signposts: Bool = false, uptimeNanos: @escaping () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        self.budgets = budgets
        self.input = input
        self.board = board
        self.signposts = signposts
        self.uptimeNanos = uptimeNanos
    }

    /// Starts a display frame's budget window. Every scheduler calls it at its tick; a second call
    /// for the same vsync (another window's link) keeps the window.
    ///
    /// - Parameters:
    ///   - timestamp: The display link's frame time; nil for a synthesized (stalled) frame.
    ///   - refreshInterval: The display's refresh period in seconds, when known.
    public func beginFrame(timestamp: CFTimeInterval?, refreshInterval: Double?) {
        if let timestamp, timestamp == lastTimestamp { return }
        lastTimestamp = timestamp
        if let refreshInterval, refreshInterval > 0 { windowLength = UInt64(refreshInterval * 1_000_000_000) }
        roll(at: uptimeNanos())
    }

    private func roll(at now: UInt64) {
        stats.frames += 1
        windowStart = now
        for index in spent.indices {
            stats.maxFrameNanos[index] = max(stats.maxFrameNanos[index], spent[index])
            spent[index] = 0
            ranThisFrame[index] = false
        }
        yieldedLastFrame = yieldedThisFrame
        yieldedThisFrame = [false, false, false]
    }

    /// Whether a task of `workClass` may start now. Unbudgeted classes always may. A budgeted one
    /// may not while input is pending (unless it yielded last frame) or once its frame budget is
    /// spent (its first task of a frame always may). A refusal is counted: the caller keeps the
    /// task for the next frame.
    public func mayRun(_ workClass: MainWorkClass) -> Bool {
        guard let index = Self.index(workClass), let budget = budgets.budget(workClass) else { return true }
        let now = uptimeNanos()
        // A task outside any tick (a request on an idle queue): a window older than one frame is over.
        if now &- windowStart >= windowLength { roll(at: now) }
        if !yieldedLastFrame[index], inputPending(now) {
            if !yieldedThisFrame[index] { stats.yieldedToInput[index] += 1 }
            yieldedThisFrame[index] = true
            return false
        }
        guard ranThisFrame[index] else { return true }
        if spentNow(index, workClass: workClass, now: now) < Self.nanos(budget) { return true }
        stats.deferredOverBudget[index] += 1
        return false
    }

    /// Runs one task of `workClass` for `owner`: publishes it on ``board`` (the watchdog names it
    /// in a stall), opens a `stall.main_task` signpost, charges its time to the class's frame
    /// budget, and reports it when it alone ran past that budget (`stall.over_budget`, the board's
    /// over-budget sink). Call ``mayRun(_:)`` first for a budgeted class.
    ///
    /// Tasks nest: a task run inside another (a queued control request inside the control batch)
    /// is published and charged as itself, and its time is taken out of the outer task's, so each
    /// class pays only for its own work and ``mayRun(_:)`` inside a task sees the time spent so far.
    ///
    /// - Returns: What `body` returns.
    @discardableResult
    public func run<T>(_ workClass: MainWorkClass, owner: String, _ body: () throws -> T) rethrows -> T {
        sequence &+= 1
        let index = Self.index(workClass)
        let task = OpenTask(workClass: workClass, owner: owner, ownerIndex: board.ownerIndex(owner), sequence: sequence,
                            start: uptimeNanos(), budgetNanos: budgets.budget(workClass).map(Self.nanos) ?? 0)
        if let index { ranThisFrame[index] = true }
        open.append(task)
        board.begin(workClass, owner: task.ownerIndex, sequence: task.sequence, startNanos: task.start, budgetNanos: task.budgetNanos)
        let interval = signposts ? Signposter.stall.begin(.stallMainTask, taskClass: workClass.description, owner: owner) : nil
        defer {
            if let interval { Signposter.stall.end(.stallMainTask, interval) }
            finish(index: index)
        }
        return try body()
    }

    private func finish(index: Int?) {
        let end = uptimeNanos()
        guard let task = open.popLast() else { return }
        let elapsed = end &- task.start
        let own = elapsed > task.childNanos ? elapsed - task.childNanos : 0
        if !open.isEmpty { open[open.count - 1].childNanos &+= elapsed }
        var over = false
        if let index {
            spent[index] &+= own
            stats.tasks[index] += 1
            stats.maxTaskNanos[index] = max(stats.maxTaskNanos[index], own)
            if own > task.budgetNanos {
                over = true
                stats.overBudgetTasks[index] += 1
                if signposts {
                    Signposter.stall.event(.stallOverBudget, "class=\(task.workClass) owner=\(task.owner) ms=\(Self.milliseconds(own)) budget_ms=\(Self.milliseconds(task.budgetNanos))")
                }
            }
        }
        board.end(MainTaskBoard.Task(workClass: task.workClass, owner: task.owner, sequence: task.sequence, startNanos: task.start,
                                     budgetNanos: task.budgetNanos), durationNanos: own, overBudget: over)
        // The outer task runs again: the watchdog names it.
        if let outer = open.last {
            board.begin(outer.workClass, owner: outer.ownerIndex, sequence: outer.sequence, startNanos: outer.start,
                        budgetNanos: outer.budgetNanos, notify: false)
        }
    }

    /// One task that started and has not returned.
    private struct OpenTask {
        var workClass: MainWorkClass
        var owner: String
        var ownerIndex: UInt32
        var sequence: UInt32
        var start: UInt64
        var budgetNanos: UInt64
        /// Time spent in tasks nested in this one.
        var childNanos: UInt64 = 0
    }

    /// What `workClass` spent this frame, its open tasks' time so far included.
    private func spentNow(_ index: Int, workClass: MainWorkClass, now: UInt64) -> UInt64 {
        var total = spent[index]
        for task in open where task.workClass == workClass {
            let elapsed = now &- task.start
            total &+= elapsed > task.childNanos ? elapsed - task.childNanos : 0
        }
        return total
    }

    /// Clears the counters (`debug.main_budget reset`).
    public func resetStats() {
        stats = Stats()
    }

    private func inputPending(_ now: UInt64) -> Bool {
        if board.pendingInputCount > 0 { return true }
        if now &- inputAnswer.at < 250_000 { return inputAnswer.pending }
        let pending = input.hasPendingInput(uptime: TimeInterval(now) / 1_000_000_000)
        inputAnswer = (now, pending)
        return pending
    }

    private static func index(_ workClass: MainWorkClass) -> Int? {
        switch workClass {
        case .input, .frame: nil
        case .visible: 0
        case .automation: 1
        case .background: 2
        }
    }

    /// `duration` in whole nanoseconds (negative durations count as zero).
    public static func nanos(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        return UInt64(clamping: seconds) &* 1_000_000_000 &+ UInt64(clamping: attoseconds / 1_000_000_000)
    }

    private static func milliseconds(_ nanos: UInt64) -> String {
        String(format: "%.2f", Double(nanos) / 1_000_000)
    }
}
