public import Foundation
import CmuxNextSignposts
import Darwin

/// The one main-thread scheduler's per-frame budget (plans/cmux-next/main-thread-budget.md).
///
/// The main thread does input dispatch, the minimal mutation of visible state and the Core
/// Animation commit; everything else runs off it. What the app still schedules there runs as a
/// task of a ``MainWorkClass``. Frame-locked work (``MainWorkClass/frame``) and injected input run
/// unbudgeted. The budgeted classes (visible, automation, background) run in priority order: a
/// frame's visible updates before its automation work, before background work.
///
/// The budget protects two things, and only those: a person's pending input and the frame.
/// - While a key or a click is pending (``InputPendingSource``, or an injected key queued on
///   ``MainTaskBoard``), every budgeted class yields, so the input is dispatched before the
///   batch; under input each class keeps to its own share (``Budgets``) of the frame.
/// - With no input pending, a class whose own share is spent may use the time the other classes
///   left (idle-time scheduling): the frame's scheduled work stops at ``Budgets/total``. Input is
///   checked again before every task, so a key that arrives during the batch stops it at the next
///   task.
/// - What the scheduled work makes AppKit and Core Animation do at the end of the pass (layout,
///   display, the commit: the run loop's before-waiting phase, ``RenderPassMeter``) is charged
///   too: the frame's scheduled work stops at ``Budgets/passTarget`` minus the last render pass
///   (``noteRenderPass(nanos:)``), when that is below ``Budgets/total``. So requests whose commits
///   are expensive run fewer per frame, and a pass stays under the 8 ms stall target.
///
/// Two rules keep every change on screen within one frame of being due:
/// - the first task of a class in a frame always fits its budget, so each class makes progress
///   every frame however long its tasks are;
/// - a class that yielded to input in one frame does not yield again in the next one (a person
///   typing at 30 keys a second never starves the sidebar).
///
/// This is batching to the display cadence, not a throttle: work over budget runs on the next
/// frame, never later. The app builds one at its composition root and hands it to the one
/// ``MainWorkScheduler``, whose single display link opens the budget's window once per frame.
///
/// ```swift
/// // A budgeted batch drains its queued work one task at a time:
/// while let work = queue.first, budget.mayRun(.visible) {
///     budget.run(.visible, owner: owner) { work() }   // owner: interned when the queue was built
/// }
/// ```
@MainActor
public final class MainFrameBudget {
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
    /// The current window was opened by a task outside any tick (an idle queue's request).
    private var windowOpenedOffTick = false
    /// Set by the ``MainWorkScheduler``'s frame scheduler while its display link exists: its ticks
    /// own the window, so a task outside a tick never opens one (it would give a run loop pass a
    /// second budget, and roll the input-yield memory between two real frames).
    var tickOwnsWindow = false {
        // The link went away: a render pass measured under it is not charged to a later window.
        didSet { if !tickOwnsWindow { renderSinceRoll = 0 } }
    }
    private var spent: [UInt64] = [0, 0, 0]
    /// Time the pending-input checks took in this window: scheduled-work overhead, counted in the
    /// frame's total like a task's time.
    private var checkSpent: UInt64 = 0
    private var ranThisFrame: [Bool] = [false, false, false]
    private var yieldedLastFrame: [Bool] = [false, false, false]
    private var yieldedThisFrame: [Bool] = [false, false, false]
    private let totalNanos: UInt64
    private let passTargetNanos: UInt64
    /// The longest render pass since the window opened (charged to the next window).
    private var renderSinceRoll: UInt64 = 0
    /// The render pass this window is charged with.
    private var renderCharge: UInt64 = 0
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
        totalNanos = Self.nanos(budgets.total)
        passTargetNanos = Self.nanos(budgets.passTarget)
        self.input = input
        self.board = board
        self.signposts = signposts
        self.uptimeNanos = uptimeNanos
    }

    /// Starts a display frame's budget window: the ``MainWorkScheduler``'s one link calls it at
    /// each tick (a second call for the same timestamp keeps the window). A window a task opened
    /// outside any tick less than one refresh period ago (an idle queue's request just before the
    /// link's first tick) is kept as this frame's, so one run loop pass never gets two budgets.
    ///
    /// - Parameters:
    ///   - timestamp: The display link's frame time; nil for a synthesized (stalled) frame.
    ///   - refreshInterval: The display's refresh period in seconds, when known.
    public func beginFrame(timestamp: CFTimeInterval?, refreshInterval: Double?) {
        if let timestamp, timestamp == lastTimestamp { return }
        lastTimestamp = timestamp
        if let refreshInterval, refreshInterval > 0 { windowLength = UInt64(refreshInterval * 1_000_000_000) }
        let now = uptimeNanos()
        if windowOpenedOffTick, now &- windowStart < windowLength {
            windowOpenedOffTick = false
            return
        }
        roll(at: now)
    }

    private func roll(at now: UInt64, offTick: Bool = false) {
        stats.frames += 1
        windowStart = now
        windowOpenedOffTick = offTick
        for index in spent.indices {
            stats.maxFrameNanos[index] = max(stats.maxFrameNanos[index], spent[index])
            spent[index] = 0
            ranThisFrame[index] = false
        }
        yieldedLastFrame = yieldedThisFrame
        yieldedThisFrame = [false, false, false]
        checkSpent = 0
        renderCharge = renderSinceRoll
        renderSinceRoll = 0
    }

    /// Records one render pass (the main run loop's before-waiting phase: layout, display and the
    /// Core Animation commit), in nanoseconds. The longest pass since a window opened is charged to
    /// the next window: its scheduled work stops at ``Budgets/passTarget`` minus that pass.
    public func noteRenderPass(nanos: UInt64) {
        renderSinceRoll = max(renderSinceRoll, nanos)
        stats.renderPasses += 1
        stats.maxRenderPassNanos = max(stats.maxRenderPassNanos, nanos)
    }

    /// The scheduled work this window may hold in all: ``Budgets/total``, less what the last render
    /// pass took past the rest of ``Budgets/passTarget``.
    private var scheduledLimitNanos: UInt64 {
        let left = passTargetNanos > renderCharge ? passTargetNanos - renderCharge : 0
        return min(totalNanos, left)
    }

    /// Whether a task of `workClass` may start now. Unbudgeted classes always may. A budgeted one
    /// may not while input is pending (unless it yielded last frame). Otherwise its first task of
    /// a frame always may, then it may while its own share is left, and past that, with no input
    /// pending, on idle time the other classes left; never once the frame's scheduled work reached
    /// its limit (``Budgets/total``, lowered by an expensive last render pass). A refusal is
    /// counted: the caller keeps the task for the next frame.
    public func mayRun(_ workClass: MainWorkClass) -> Bool {
        guard let index = Self.index(workClass), let budget = budgets.budget(workClass) else { return true }
        let now = uptimeNanos()
        // A task outside any tick while no budgeted link runs (a request on an idle app): a window
        // older than one frame is over. Never while the link runs (its ticks own the window) and
        // never while a task runs (a long batch would reset its own budget and keep the main
        // thread past the frame).
        if open.isEmpty, !tickOwnsWindow, now &- windowStart >= windowLength { roll(at: now, offTick: true) }
        let pending = inputPending(now)
        if pending, !yieldedLastFrame[index] {
            if !yieldedThisFrame[index] { stats.yieldedToInput[index] += 1 }
            yieldedThisFrame[index] = true
            return false
        }
        guard ranThisFrame[index] else { return true }
        let underLimit = frameSpentNow(now) < scheduledLimitNanos
        if underLimit, spentNow(index, workClass: workClass, now: now) < Self.nanos(budget) { return true }
        // Idle time: nothing a person waits on is pending, so the share only orders the classes.
        if !pending, underLimit {
            stats.idleTasks[index] += 1
            return true
        }
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
    /// - Parameters:
    ///   - workClass: The task's class.
    ///   - owner: Its owner, interned on this budget's ``board`` when the queue or method was built
    ///     (``MainTaskBoard/owner(_:)``), so starting the task takes no lock.
    ///   - body: The task.
    /// - Returns: What `body` returns.
    @discardableResult
    public func run<T>(_ workClass: MainWorkClass, owner: MainTaskOwner, _ body: () throws -> T) rethrows -> T {
        sequence &+= 1
        let index = Self.index(workClass)
        let task = OpenTask(workClass: workClass, owner: owner, sequence: sequence, start: uptimeNanos(),
                            budgetNanos: budgets.budget(workClass).map(Self.nanos) ?? 0)
        if let index { ranThisFrame[index] = true }
        open.append(task)
        board.begin(workClass, owner: owner.index, sequence: task.sequence, startNanos: task.start, budgetNanos: task.budgetNanos)
        let interval = signposts ? Signposter.stall.begin(.stallMainTask, taskClass: workClass.description, owner: owner.name) : nil
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
                    Signposter.stall.event(.stallOverBudget, "class=\(task.workClass) owner=\(task.owner.name) ms=\(Self.milliseconds(own)) budget_ms=\(Self.milliseconds(task.budgetNanos))")
                }
            }
        }
        board.end(MainTaskBoard.Task(workClass: task.workClass, owner: task.owner.name, sequence: task.sequence, startNanos: task.start,
                                     budgetNanos: task.budgetNanos), durationNanos: own, overBudget: over)
        // The outer task runs again: the watchdog names it.
        if let outer = open.last {
            board.begin(outer.workClass, owner: outer.owner.index, sequence: outer.sequence, startNanos: outer.start,
                        budgetNanos: outer.budgetNanos, notify: false)
        }
    }

    /// One task that started and has not returned.
    private struct OpenTask {
        var workClass: MainWorkClass
        var owner: MainTaskOwner
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

    /// What every budgeted class spent this frame, open tasks included (each task's own time),
    /// plus the pending-input checks.
    private func frameSpentNow(_ now: UInt64) -> UInt64 {
        var total = spent.reduce(0, &+) &+ checkSpent
        for task in open where task.workClass.isBudgeted {
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
        let took = uptimeNanos() &- now
        stats.inputChecks += 1
        stats.maxInputCheckNanos = max(stats.maxInputCheckNanos, took)
        // A check inside a task is already in that task's time.
        if open.isEmpty { checkSpent &+= took }
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
