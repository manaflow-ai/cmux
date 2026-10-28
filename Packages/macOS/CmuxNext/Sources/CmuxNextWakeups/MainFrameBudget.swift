public import Foundation
import CmuxNextSignposts
import Darwin

/// The one main-thread scheduler's per-frame budget (plans/cmux-next/main-thread-budget.md).
///
/// The main thread does input dispatch, the minimal mutation of visible state and the Core
/// Animation commit; everything else runs off it. What the app still schedules there runs as a
/// task of a ``MainWorkClass``. Frame-locked work (``MainWorkClass/frame``) and injected input run
/// unbudgeted. The budgeted classes (userBlocking, visible, automation, background) run in that
/// order; userBlocking, the rest of a person's action, has its own rules (``UserBlockingFrame``).
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
/// - Once render passes were measured, a tick also gives its frame a deadline in wall time,
///   Chromium's main-frame deadline (`cc/scheduler/scheduler.cc`): the frame's scheduled work
///   stops at the tick's target time (the vsync it is due for), or ``Budgets/passTarget`` after
///   the tick when that is sooner, less the commit estimate (the 95th percentile of the last 32
///   frames' passes, ``MainCommitMeter``, or the last pass when that is longer). The deadline only
///   ever ends the work earlier than the fixed limit, which still holds: it counts what the fixed
///   limit cannot see, a tick that ran late, the frame-locked work before the batch and a target
///   nearer than one refresh period. At 120 Hz with 3 ms passes, 2 ms of frame-locked work leaves
///   the batch 3 ms, not 4. A stalled frame or a window a task opened outside any tick has no
///   deadline of its own.
///
/// Two rules keep every change on screen within one frame of being due:
/// - the first task of a class in a frame always fits its budget, so each class makes progress
///   every frame however long its tasks are;
/// - a class that yielded to input in one frame does not yield again in the next one (a person
///   typing at 30 keys a second never starves the sidebar).
///
/// A discrete input whose turn expects a frame opens an input response
/// (``noteDiscreteInput(expectsFrame:)``): automation and background wait until the first
/// display-link tick after it has rendered (``noteTickRenderEnded()``), at most 100 ms. For 500 ms
/// after a discrete input they start at most one task per 100 ms, and one each 100 ms even under
/// pending input, at the first frame without an open input response (``InputResponse``), in place
/// of the every-other-frame rule, which visible keeps.
///
/// A late shown frame comes first (``RenderStarvationGuard``, Chrome's `kRenderingStarved`): every
/// budgeted class waits for that link's next tick, whatever the rules above say.
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
    /// The 60 Hz shares; ``shares`` are this frame's (scaled to its refresh period after commit).
    public let budgets: Budgets
    /// Where each frame's budgeted batch runs: in the tick, or in its own turn after the commit.
    public let placement: BudgetedBatchPlacement
    /// This frame's shares: ``budgets`` scaled to the frame's refresh period under the after-commit placement.
    public private(set) var shares: Budgets
    /// What the budget ran, held and measured since it was made (`debug.main_budget`, tests).
    public private(set) var stats = Stats()
    public internal(set) var budgetTurnStats = BudgetTurnStats()
    /// The main run loop's turns: each task this budget runs is a scheduled span in the turn
    /// (``MainTurnMeter``). The composition root makes it observe the main run loop.
    public let turns: MainTurnMeter
    private let input: any InputPendingSource
    /// The app's one pending-input source, which the budget's yields read: other main-thread work that
    /// yields to the person's input (the in-process CEF pump) reads the same one.
    public var pendingInput: any InputPendingSource { input }
    /// The budget's clock; ``ObservationCauses`` times the input-response pass's cap on it, and the
    /// ``IdleScheduler`` reads the same one.
    let uptimeNanos: () -> UInt64
    /// The budget's clock where any thread may read it (`CLOCK_UPTIME_RAW` in the app, or an
    /// injected ``init(budgets:input:board:signposts:starvation:clock:turns:placement:)`` clock): an off-main post reads its
    /// enqueue time with it on the posting thread, as Chrome sets `PendingTask::queue_time` at
    /// `PostTask`. Nil for a main-actor-only test clock (``init(budgets:input:board:signposts:starvation:uptimeNanos:turns:placement:)``),
    /// whose off-main posts are timed from their arrival on main.
    public nonisolated let postClock: (@Sendable () -> UInt64)?
    private let signposts: Bool
    /// The rendering starvation guard (nil: never starved).
    public let starvation: RenderStarvationGuard?
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
    private var spent: [UInt64] = [0, 0, 0, 0]
    /// Time the pending-input checks took in this window: scheduled-work overhead, counted in the
    /// frame's total like a task's time.
    private var checkSpent: UInt64 = 0
    private var ranThisFrame: [Bool] = [false, false, false, false]
    private var yieldedLastFrame: [Bool] = [false, false, false, false]
    private var yieldedThisFrame: [Bool] = [false, false, false, false]
    private var totalNanos: UInt64 // shares.total
    private let passTargetNanos: UInt64
    private var sharesIntervalNanos: UInt64 = 0 // the period shares were scaled to
    /// The longest render pass since the window opened (charged to the next window).
    private var renderSinceRoll: UInt64 = 0
    /// The render pass this window is charged with.
    private var renderCharge: UInt64 = 0
    /// The last frames' render passes: the commit the deadline leaves room for.
    private var commitMeter = MainCommitMeter()
    /// When this window's scheduled work stops at the latest (``uptimeNanos`` time); nil: no
    /// deadline, the fixed limit alone.
    private(set) var deadline: UInt64?
    /// Counts the frame windows opened: a continuation posted in one runs only once a later one opened
    /// (``MainWorkScheduler/postContinuation(_:owner:file:line:_:)``).
    public private(set) var frameSerial: UInt64 = 0
    private var sequence: UInt32 = 0
    /// The tasks that started and have not returned, the innermost last.
    var open: [OpenTask] = []
    /// Per nested run loop running now, innermost last: the sequence of the task that waits in it
    /// (nil: none ran it).
    var parkedBy: [UInt32?] = []
    /// The input check's last answer and when (a frame asks several times; the answer is reused
    /// for a quarter millisecond).
    private var inputAnswer: (at: UInt64, pending: Bool) = (0, false)
    private var response = InputResponse()
    private var responseYieldThisFrame: [Bool] = [false, false, false, false]
    private var burstWaitThisFrame: [Bool] = [false, false, false, false]
    private var userBlocking = UserBlockingFrame()
    /// Set by the ``MainWorkScheduler``: asks its display link for a tick, so an open input
    /// response gets the tick render that closes it even while no budgeted client is active.
    var requestTick: (@MainActor () -> Void)?
    /// Told when a response opens or closes, or a discrete dispatch begins or ends (the
    /// ``InputResponsePass`` sets itself here).
    weak var inputResponsePass: InputResponsePass?
    /// Discrete inputs whose dispatch is in progress (``noteDiscreteDispatch(began:)``).
    private var discreteDispatches = 0

    /// - Parameters:
    ///   - budgets: Per-class budgets (default: the measured split in ``Budgets``).
    ///   - input: The pending-input check (the app: ``SessionInputPending``; tests: a fake).
    ///   - board: Where the running task is published for the watchdog.
    ///   - signposts: Whether each task opens a `stall.main_task` interval and a long turn emits
    ///     `stall.main_turn` (the app: true).
    ///   - starvation: Holds budgeted work while a shown frame is late (nil: never).
    ///   - clock: The clock (`CLOCK_UPTIME_RAW` nanoseconds), read on main and by off-main posts.
    ///   - turns: The run-loop turn meter (default: one on this clock).
    ///   - placement: Where the frame's budgeted batch runs (default: in the tick).
    public convenience init(budgets: Budgets = Budgets(), input: any InputPendingSource = NoInputPending(), board: MainTaskBoard = MainTaskBoard(),
                            signposts: Bool = false, starvation: RenderStarvationGuard? = nil,
                            clock: @escaping @Sendable () -> UInt64 = { MainTaskPost.uptimeNanos() }, turns: MainTurnMeter? = nil,
                            placement: BudgetedBatchPlacement = .inTick) {
        self.init(budgets: budgets, input: input, board: board, signposts: signposts, starvation: starvation,
                  mainClock: clock, postClock: clock, turns: turns, placement: placement)
    }

    /// A budget on a clock only the main actor reads (a test's hand-moved clock): off-main posts
    /// have no ``postClock``.
    ///
    /// - Parameters:
    ///   - budgets: Per-class budgets (default: the measured split in ``Budgets``).
    ///   - input: The pending-input check.
    ///   - board: Where the running task is published for the watchdog.
    ///   - signposts: Whether each task opens a `stall.main_task` interval and a long turn emits `stall.main_turn`.
    ///   - starvation: Holds budgeted work while a shown frame is late (nil: never).
    ///   - uptimeNanos: The clock, in nanoseconds; tests inject one they move.
    ///   - turns: The run-loop turn meter (default: one on this clock).
    ///   - placement: Where the frame's budgeted batch runs (default: in the tick).
    public convenience init(budgets: Budgets = Budgets(), input: any InputPendingSource = NoInputPending(), board: MainTaskBoard = MainTaskBoard(),
                            signposts: Bool = false, starvation: RenderStarvationGuard? = nil, uptimeNanos: @escaping () -> UInt64,
                            turns: MainTurnMeter? = nil, placement: BudgetedBatchPlacement = .inTick) {
        self.init(budgets: budgets, input: input, board: board, signposts: signposts, starvation: starvation,
                  mainClock: uptimeNanos, postClock: nil, turns: turns, placement: placement)
    }

    private init(budgets: Budgets, input: any InputPendingSource, board: MainTaskBoard, signposts: Bool,
                 starvation: RenderStarvationGuard?, mainClock: @escaping () -> UInt64, postClock: (@Sendable () -> UInt64)?,
                 turns: MainTurnMeter?, placement: BudgetedBatchPlacement) {
        (self.budgets, shares, self.placement) = (budgets, budgets, placement)
        self.turns = turns ?? MainTurnMeter(signposts: signposts, uptimeNanos: mainClock)
        self.starvation = starvation
        totalNanos = Self.nanos(budgets.total)
        passTargetNanos = Self.nanos(budgets.passTarget)
        self.input = input
        self.board = board
        self.signposts = signposts
        uptimeNanos = mainClock
        self.postClock = postClock
        parkedBy.reserveCapacity(MainTurnMeter.maxDepth)
        self.turns.nestedLoopRunning = { [weak self] running, now in self?.nestedLoop(running: running, at: now) }
    }

    /// Starts a display frame's budget window: the ``MainWorkScheduler``'s one link calls it at
    /// each tick (a second call for the same timestamp keeps the window). A window a task opened
    /// outside any tick less than one refresh period ago (an idle queue's request just before the
    /// link's first tick) is kept as this frame's, so one run loop pass never gets two budgets.
    ///
    /// With render-pass history, a tick's frame also gets a deadline: its scheduled work stops in
    /// time for the commit to end by the target time and by ``Budgets/passTarget`` after the tick.
    ///
    /// - Parameters:
    ///   - timestamp: The display link's frame time; nil for a synthesized (stalled) frame.
    ///   - targetTimestamp: The time the frame is due on screen (the link's `targetTimestamp`);
    ///     nil: `timestamp` plus `refreshInterval`.
    ///   - refreshInterval: The display's refresh period in seconds, when known.
    ///   - ranAt: When the tick runs on main, on the clock of `timestamp` (the ``FrameScheduler``'s
    ///     display clock); nil: at `timestamp`.
    public func beginFrame(timestamp: CFTimeInterval?, targetTimestamp: CFTimeInterval? = nil, refreshInterval: Double?,
                           ranAt: CFTimeInterval? = nil) { // perf-hot: 0.5ms frame-tick (every frame)
        if let timestamp, timestamp == lastTimestamp { return }
        lastTimestamp = timestamp
        response.noteTick()
        turns.noteTurn(.tick)
        if let refreshInterval, refreshInterval > 0 { windowLength = UInt64(refreshInterval * 1_000_000_000) }
        if placement == .afterCommit, windowLength != sharesIntervalNanos {
            (sharesIntervalNanos, shares) = (windowLength, budgets.scaled(toIntervalNanos: windowLength))
            totalNanos = Self.nanos(shares.total)
        }
        let now = uptimeNanos()
        if windowOpenedOffTick, now &- windowStart < windowLength {
            windowOpenedOffTick = false
        } else {
            roll(at: now)
        }
        guard let timestamp else { return }
        let target = targetTimestamp ?? refreshInterval.map { timestamp + $0 }
        if let target, target > timestamp {
            deadline = frameDeadline(now: now, timestamp: timestamp, target: target, ranAt: ranAt ?? timestamp)
        }
    }

    /// When the frame's scheduled work stops at the latest, in ``uptimeNanos`` time: the pass ends
    /// by `target` and by ``Budgets/passTarget`` after the tick, and the commit comes after the
    /// work (``MainCommitMeter``'s p95, or the last pass when longer, so one expensive commit
    /// lowers the next frame at once). The tick ran `ranAt - timestamp` late; a tick too late for
    /// any work gives `now` (each class's first task still runs). Nil with no history. After commit
    /// the budget turn's work ends by the next vsync less the commit (no history: the vsync itself).
    private func frameDeadline(now: UInt64, timestamp: CFTimeInterval, target: CFTimeInterval,
                               ranAt: CFTimeInterval) -> UInt64? {
        guard let estimate = commitMeter.p95() ?? (placement == .afterCommit ? 0 : nil) else { return nil }
        let commit = max(estimate, renderCharge)
        let frame = Self.nanos(seconds: target - timestamp)
        let passEnd = placement == .afterCommit ? frame : min(frame, passTargetNanos)
        let workEnd = passEnd > commit ? passEnd - commit : 0
        let late = Self.nanos(seconds: ranAt - timestamp)
        return workEnd > late ? now &+ (workEnd - late) : now
    }

    /// `seconds` in whole nanoseconds (negative counts as zero).
    private static func nanos(seconds: CFTimeInterval) -> UInt64 {
        seconds > 0 ? UInt64(seconds * 1_000_000_000) : 0
    }

    /// The commit estimate the frame deadline leaves room for (``MainCommitMeter``), in
    /// nanoseconds; nil before any render pass was measured.
    public var commitEstimateNanos: UInt64? { commitMeter.p95() }

    private func roll(at now: UInt64, offTick: Bool = false) {
        stats.frames += 1
        frameSerial &+= 1
        windowStart = now
        windowOpenedOffTick = offTick
        for index in spent.indices {
            stats.maxFrameNanos[index] = max(stats.maxFrameNanos[index], spent[index])
            spent[index] = 0
            ranThisFrame[index] = false
        }
        yieldedLastFrame = yieldedThisFrame
        yieldedThisFrame = [false, false, false, false]
        responseYieldThisFrame = [false, false, false, false]
        burstWaitThisFrame = [false, false, false, false]
        userBlocking.roll()
        checkSpent = 0
        if renderSinceRoll > 0 { commitMeter.record(renderSinceRoll) }
        renderCharge = renderSinceRoll
        renderSinceRoll = 0
        deadline = nil
    }

    /// Records one render pass (the main run loop's before-waiting phase: layout, display and the
    /// Core Animation commit), in nanoseconds. The longest pass since a window opened is charged to
    /// the next window (its scheduled work stops at ``Budgets/passTarget`` minus that pass) and is
    /// the frame's sample of the commit estimate that places the next deadlines (``MainCommitMeter``).
    /// The pass also ends an input response that a link tick after the input rendered in
    /// (``noteTickRenderEnded()``), or that a person's completion answered after the input's own
    /// commit (``noteAnswered(_:)``: the pass is the completion's commit).
    public func noteRenderPass(nanos: UInt64) {
        renderSinceRoll = max(renderSinceRoll, nanos)
        stats.renderPasses += 1
        stats.maxRenderPassNanos = max(stats.maxRenderPassNanos, nanos)
        if userBlocking.takeCommit() { noteUserBlockingCommit() }
        noteTickRenderEnded()
    }

    /// A discrete input (key down, mouse down, an injected key) was dispatched in this turn. When
    /// the turn expects a frame (its action changed what shows, a view asked for display, the
    /// terminal asked for a draw), it opens the input response: automation and background wait
    /// until ``noteTickRenderEnded()`` (Chrome `is_frame_expected_after_discrete_input`). Either
    /// way it starts or extends the typing burst. An open response asks the scheduler's link for
    /// the tick that closes it.
    public func noteDiscreteInput(expectsFrame: Bool) {
        record(response.noteInput(expectsFrame: expectsFrame, at: uptimeNanos()))
        userBlocking.noteInput(expectsFrame: expectsFrame, inDispatch: isDiscreteDispatchOpen)
        if expectsFrame { requestTick?() }
        inputResponsePass?.inputResponseChanged()
    }

    /// The render pass of a display-link tick of the budget's scheduler ended. It closes the input
    /// response when that tick began after the latest frame-expecting input, so the input's own
    /// turn (its commit runs before any tick) never closes it. ``noteRenderPass(nanos:)`` calls it
    /// for every pass the scheduler measures.
    public func noteTickRenderEnded() {
        record(response.noteTickRenderEnded(at: uptimeNanos()))
    }

    /// A discrete input's dispatch began or ended (the App's `InputDispatchContext`: before it
    /// dispatches, and after it reported ``noteDiscreteInput(expectsFrame:)``). While one is in
    /// progress, the ``InputResponsePass`` accepts the person's items and is on the run loop, so
    /// a run loop nested in the dispatch runs it at its first wait.
    public func noteDiscreteDispatch(began: Bool) {
        if began { userBlocking.noteDispatchBegan(outermost: discreteDispatches == 0) }
        discreteDispatches = began ? discreteDispatches + 1 : max(0, discreteDispatches - 1)
        inputResponsePass?.inputResponseChanged()
    }

    /// Whether a discrete input's dispatch is in progress (``noteDiscreteDispatch(began:)``).
    public var isDiscreteDispatchOpen: Bool { discreteDispatches > 0 }

    /// A user-blocking task committed the input's result: the input response closes.
    public func noteUserBlockingCommit() {
        record(response.close(at: uptimeNanos()))
    }

    /// The discrete input an action run starting now answers: the outermost dispatch in progress;
    /// nil outside a dispatch (a CLI run, a reply's later turn). Its completion hands it to
    /// ``noteAnswered(_:)``.
    public var answerableInput: InputToken? { userBlocking.answerable(dispatchOpen: isDiscreteDispatchOpen) }

    /// The running userBlocking task is the completion of a run that answers `input` (a person's
    /// action whose remote half replied, `ActionRegistry`). When `input` opened the open input
    /// response and its own turn has committed, the next render pass, this task's commit, closes
    /// the response (``UserBlockingFrame``). Outside a userBlocking task it does nothing.
    public func noteAnswered(_ input: InputToken) {
        guard open.last?.workClass == .userBlocking else { return }
        userBlocking.noteAnswered(input, responseOpen: response.isOpen(at: uptimeNanos()))
    }

    /// Whether an input response is open now: automation, background and idle work wait.
    public var isInputResponseOpen: Bool { response.isOpen(at: uptimeNanos()) }

    private func record(_ closed: InputResponse.Closed?) {
        guard let closed else { return }
        if closed.capped { stats.inputResponseCapHits += 1 }
        stats.maxInputResponseNanos = max(stats.maxInputResponseNanos, closed.nanos)
        inputResponsePass?.inputResponseChanged()
    }

    /// The scheduled work this window may hold in all: ``Budgets/total``, less what the last render
    /// pass took past the rest of ``Budgets/passTarget``.
    private var scheduledLimitNanos: UInt64 {
        // After commit: the refresh period less the input reserve and the render pass (Budgets/passTargetNanos).
        let left = placement == .afterCommit ? budgets.passTargetNanos(intervalNanos: windowLength, renderNanos: renderCharge)
            : passTargetNanos > renderCharge ? passTargetNanos - renderCharge : 0
        return min(totalNanos, left)
    }

    /// Whether the frame's scheduled work may go on at `now`: under the fixed limit (what the
    /// window already spent counts, a window a task opened before the tick included) and before the
    /// frame's deadline, when it has one.
    func underFrameLimit(_ now: UInt64) -> Bool {
        if let deadline, now >= deadline { return false }
        return frameSpentNow(now) < scheduledLimitNanos
    }

    /// Whether a task of `workClass` may start now. Unbudgeted classes always may; no budgeted one
    /// may while a shown frame is late (``isRenderStarved``). Automation and background may not
    /// while an input response is open; in a typing burst they follow its rate
    /// (``InputResponse/Burst``), and a due task runs under pending input. userBlocking follows
    /// neither, has no idle time and owes visible its share after a flood (``UserBlockingFrame``).
    /// Otherwise a budgeted class may not while input is pending (unless it yielded last frame).
    /// Past that, its first task of a frame always may, then it may while its own share is left,
    /// and past that, with no input pending and no input response open, on idle time the other
    /// classes left; never once the frame's scheduled work reached its limit (``Budgets/total``,
    /// lowered by an expensive last render pass) or its deadline passed. A refusal is counted: the
    /// caller keeps the task for the next frame.
    ///
    /// ``MainWorkClass/idle`` may run while no shown frame is late, no input response is open and no
    /// input is pending: the ``IdleScheduler`` asks before each idle task and ends its idle period on
    /// a refusal. Its deadline, not a frame share, bounds it.
    public func mayRun(_ workClass: MainWorkClass) -> Bool {
        if workClass == .idle {
            let now = uptimeNanos()
            return !isRenderStarved && !response.isOpen(at: now) && !inputPending(now)
        }
        guard let index = Self.index(workClass), let budget = shares.budget(workClass) else { return true }
        if heldForLateFrame(index) { return false }
        let now = uptimeNanos()
        // A task outside any tick while no budgeted link runs (a request on an idle app): a window
        // older than one frame is over. Never while the link runs (its ticks own the window) and
        // never while a task runs (a long batch would reset its own budget and keep the main
        // thread past the frame).
        if !taskRuns, !tickOwnsWindow, now &- windowStart >= windowLength { roll(at: now, offTick: true) }
        record(response.expire(at: now))
        let responseOpen = response.isOpen(at: now)
        let pending = inputPending(now)
        if workClass > .visible {
            switch response.burst(index, at: now) {
            case .due:
                // The person's frame goes first: an open response holds a due task one frame.
                if responseOpen, response.responseHoldsDue(index, at: now, frameNanos: windowLength) {
                    return hold(index, \.yieldedToInputResponse, &responseYieldThisFrame)
                }
                return true
            case .wait: return hold(index, \.waitedForBurstSlot, &burstWaitThisFrame)
            case .free:
                if responseOpen { return hold(index, \.yieldedToInputResponse, &responseYieldThisFrame) }
                if pending { return hold(index, \.yieldedToInput, &yieldedThisFrame) }
            case .outside:
                // A response opens only on an input, and ``InputResponse/cap`` < ``InputResponse/burstLength``.
                assert(!responseOpen, "an input response is open outside its typing burst")
            }
        }
        if pending, !yieldedLastFrame[index] { return hold(index, \.yieldedToInput, &yieldedThisFrame) }
        guard ranThisFrame[index] else { return true }
        let underLimit = underFrameLimit(now)
        let underShare = underLimit && spentNow(index, workClass: workClass, now: now) < Self.nanos(budget)
        if userBlocking.mayContinue(workClass, underShare: underShare) { return true }
        // Idle time: nothing a person waits on is pending, so the share only orders the classes.
        if !pending, !responseOpen, underLimit, workClass != .userBlocking {
            stats.idleTasks[index] += 1
            return true
        }
        stats.deferredOverBudget[index] += 1
        userBlocking.noteDeferred(workClass)
        return false
    }

    /// Holds a task of class `index` for the next frame, counted in `stat` once per frame (`seen`).
    private func hold(_ index: Int, _ stat: WritableKeyPath<Stats, [Int]>, _ seen: inout [Bool]) -> Bool {
        if !seen[index] { stats[keyPath: stat][index] += 1 }
        seen[index] = true
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
    ///   - posted: Where, when and in which node state it was posted: the board names its site while
    ///     it runs, and its ledger records its wait (nil: run time only, under node state `none`).
    ///   - body: The task.
    /// - Returns: What `body` returns.
    @discardableResult
    public func run<T>(_ workClass: MainWorkClass, owner: MainTaskOwner, posted post: MainTaskPost? = nil, _ body: () throws -> T) rethrows -> T {
        try runTask(workClass, owner: owner, posted: post, inline: false, body)
    }

    /// ``run(_:owner:posted:_:)``, and ``runInline(_:owner:posted:_:)`` with `inline` (work the scheduler did not pick).
    func runTask<T>(_ workClass: MainWorkClass, owner: MainTaskOwner, posted post: MainTaskPost?, inline: Bool,
                    _ body: () throws -> T) rethrows -> T {
        sequence &+= 1
        let index = Self.index(workClass)
        var task = OpenTask(workClass: workClass, owner: owner, sequence: sequence, start: uptimeNanos(),
                            budgetNanos: shares.budget(workClass).map(Self.nanos) ?? 0, post: post)
        task.isInline = inline
        task.covers = board.spanCovered(outer: open.last)
        if let index, !inline { (ranThisFrame[index], turns.ranBudgetedTask) = (true, true) }
        open.append(task)
        turns.beginSpan(.scheduled, at: task.start)
        board.begin(workClass, owner: owner.index, sequence: task.sequence, startNanos: task.start, budgetNanos: task.budgetNanos,
                    hangAtNanos: task.hangAtNanos)
        if let post { board.notePostedFrom(post.site) }
        let interval = signposts
            ? Signposter.stall.begin(.stallMainTask, taskClass: workClass.description, owner: owner.name,
                                     classID: UInt8(truncatingIfNeeded: workClass.rawValue), ownerID: owner.index)
            : nil
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
        let own = task.ownNanos(at: end)
        // An exception unwound it past the exit of a nested loop it ran: the board names it for its end.
        if task.parkedSince != nil { publish(task) }
        if !open.isEmpty {
            // A task run inside the outer task's nested loop is in that loop's time already.
            if open[open.count - 1].parkedSince == nil { open[open.count - 1].addChild(elapsed, overSpan: task.covers != nil) }
            if open[open.count - 1].workClass == task.workClass, !task.isInline { open[open.count - 1].isBatch = true }
        }
        turns.endTask(at: end, ownNanos: own)
        var over = false
        if let index {
            // The typing burst's rate counts requests, not the batch that ran them (or ran none), nor inline work.
            if !task.isBatch, !task.isInline { response.noteTask(index, startedAt: task.start) }
            spent[index] &+= own
            stats.tasks[index] += 1
            stats.maxTaskNanos[index] = max(stats.maxTaskNanos[index], own)
            if own > task.budgetNanos {
                over = true
                stats.overBudgetTasks[index] += 1
                if signposts {
                    Signposter.stall.event(.stallOverBudget, taskClass: task.workClass.description, owner: task.owner.name,
                                           classID: UInt8(truncatingIfNeeded: task.workClass.rawValue), ownerID: task.owner.index,
                                           ownNanos: own, budgetNanos: task.budgetNanos)
                }
            }
        }
        board.end(MainTaskBoard.Task(workClass: task.workClass, owner: task.owner.name, sequence: task.sequence, startNanos: task.start,
                                     budgetNanos: task.budgetNanos), durationNanos: own, overBudget: over)
        if !task.ranNothing {
            board.ledger.ended(task.workClass, owner: task.owner.index, post: task.post, startNanos: task.start, runNanos: own)
        }
        // The work it ran over runs again: the watchdog names it.
        publishCovered(by: task, elapsed: elapsed)
    }

    /// What `workClass` spent this frame, its open tasks' time so far included.
    func spentNow(_ index: Int, workClass: MainWorkClass, now: UInt64) -> UInt64 {
        var total = spent[index]
        for task in open where task.workClass == workClass { total &+= task.ownNanos(at: now) }
        return total
    }

    /// What every budgeted class spent this frame, open tasks included (each task's own time),
    /// plus the pending-input checks.
    private func frameSpentNow(_ now: UInt64) -> UInt64 {
        var total = spent.reduce(0, &+) &+ checkSpent
        for task in open where task.workClass.isBudgeted { total &+= task.ownNanos(at: now) }
        return total
    }

    /// Clears the counters and the turn meter's (`debug.main_budget reset`; ``MainOwnerLedger/reset()`` is off main).
    public func resetStats() {
        (stats, budgetTurnStats) = (Stats(), BudgetTurnStats())
        turns.reset()
        starvation?.resetStats()
    }

    func inputPending(_ now: UInt64) -> Bool {
        if board.pendingInputCount > 0 { return true }
        if now &- inputAnswer.at < 250_000 { return inputAnswer.pending }
        let pending = input.hasPendingInput(uptime: TimeInterval(now) / 1_000_000_000)
        let took = uptimeNanos() &- now
        stats.inputChecks += 1
        stats.maxInputCheckNanos = max(stats.maxInputCheckNanos, took)
        // A check inside a task is already in that task's time.
        if !taskRuns { checkSpent &+= took }
        inputAnswer = (now, pending)
        return pending
    }
}
