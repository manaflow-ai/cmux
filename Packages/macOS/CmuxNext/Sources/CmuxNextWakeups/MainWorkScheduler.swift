public import QuartzCore

/// The app's one main-thread scheduler for budgeted work (plans/cmux-next/main-thread-budget.md):
/// the per-frame ``MainFrameBudget`` and the scheduler its batches tick on, on the main display's
/// shared link (``DisplayClock``).
///
/// The app builds one at its composition root and passes it by init to everything that runs a
/// budgeted batch (the control work queue, the watchdog's board) and to the daemon services, whose
/// store drain is a frame client on its link (it ticks first, whole, every frame): there
/// is no shared instance. Budgeted clients exist only here (``FrameClient/init(owner:budgeted:on:onFrame:)``,
/// ``FrameBatchQueue/init(owner:budgeted:on:)``), so the budget's window opens once per real frame
/// on the main display's link, never once per tick of each display (two displays at 60 and 120 Hz
/// would otherwise roll it several times a frame). It ticks on that link only while one of its
/// clients has work or an input response waits for its tick; an idle app has no frame wakeups
/// from it. On each tick its frame-locked clients go first, then the window schedulers on that
/// display, then its budgeted classes.
///
/// Main-thread work that is not a batch is posted in a class with an owner
/// (``post(_:owner:file:line:_:)``, ``postFromAnyThread(_:owner:file:line:_:)``, ``apply(_:owner:file:line:_:)``,
/// and ``BackgroundWork/Pending/reply(on:class:owner:file:line:_:)`` for off-main work whose result
/// comes back): each class has one FIFO queue here, and the board names the posting site of the
/// task it runs. A GCD block, a run-loop block or a notification takes any ``MainWorkClass``
/// through ``post(class:owner:file:line:_:)`` and ``callbackClass(_:owner:file:line:)``: input and
/// frame work runs at once, the rest waits behind a person's input (the ``MainJobGate``) and then
/// for its class's budget (MainWorkScheduler+Classed.swift).
///
/// It owns the app's ``StartupPhase``: while launching, background work (posts and budgeted
/// batches) waits in its queue for the reveal, and idle work for the settle; input, frame,
/// visible and automation work never wait.
///
/// Idle work (``MainWorkClass/idle``) is posted with ``postIdle(owner:maxDelay:node:file:line:_:)``
/// and runs in the ``idle`` scheduler's idle periods, each task with a deadline.
///
/// ```swift
/// // The composition root, with the app's one display clock:
/// let displays = DisplayClock()
/// let mainWork = MainWorkScheduler(budget: MainFrameBudget(input: SessionInputPending(events: WindowServerInputEvents(input: inputTap)), signposts: true),
///                                  displays: displays)
/// FrameScheduler.install(displays: displays, energy: mainWork.energy)
/// let requests = FrameBatchQueue(owner: "Control.frames", budgeted: .automation, on: mainWork)
/// mainWork.post(.automation, owner: "browser-host.open") { host.open(url) }
///
/// // A test drives the frames by hand:
/// let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ in FakeLink() }
/// work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
/// ```
@MainActor
public final class MainWorkScheduler {
    /// The per-frame budget every budgeted batch draws on.
    public nonisolated let budget: MainFrameBudget
    /// The budget's board, readable from any thread (``postFromAnyThread(_:owner:file:line:_:)``
    /// interns owners on it off the main thread).
    public nonisolated let board: MainTaskBoard
    /// The scheduler the budgeted clients tick on (on the main display); the daemon services'
    /// drains are frame clients on it, so they tick before the window schedulers and the budgeted classes.
    public let frames: FrameScheduler
    /// The launch's phases: which classes are held until the reveal or the settle.
    public let startup: StartupPhase
    /// The cause of the changes made now and the person-caused observations the input-response
    /// pass applies: one per scheduler, shared by every ``VisibleObservation`` on it and the
    /// daemon store's drain (p06-scheduler.md: "The scheduler holds `currentCause`").
    public let causes: ObservationCauses
    /// The observers' per-owner counts (`debug.observations`): every ``VisibleObservation`` on this
    /// scheduler interns its owner here, and the app's other observers take an owner from it too.
    /// Its counters are atomics, so the report reads them from any thread.
    public nonisolated let observations = ObservationLedger()
    /// The app's one Energy Saver policy: its owners write it once (the App's
    /// `EnergyPolicyDriver`), and everything this scheduler is passed to reads it from here, so no
    /// consumer needs a shared instance or a second injection path.
    public nonisolated let energy: EnergyPolicySource
    /// The main thread's one deadline timer, on ``energy``'s wake grid (`delayed_work_timer_`,
    /// base/message_loop/message_pump_apple.mm): main-thread DemandTimer deadlines and CEF's delayed
    /// pump share it.
    public nonisolated let wakeUps: MainWakeUpQueue
    /// The idle class's periods and queue (``postIdle(owner:maxDelay:node:file:line:_:)``).
    public let idle: IdleScheduler
    /// The priority-ordered main executor this scheduler installed (task 202, default off), nil while none.
    public private(set) var mainExecutorHook: MainExecutorHook?
    /// What ``installMainExecutorHook(requested:)`` found (``MainExecutorHook/State/off`` until it is asked).
    public private(set) var mainExecutorHookState: MainExecutorHook.State = .off
    /// A layout plan applied in this run loop turn and not committed yet (``PlanApplyTurn``): the layout
    /// notes it, the in-process CEF pump starts no slice inside it.
    public let planApplies: PlanApplyTurn
    /// The CPU-time budget of hidden nodes' work, on the budget's clock: every ``MainTaskQueue`` and
    /// ``MainDeadline`` on this scheduler charges its hidden runs to this one pool.
    public let hiddenBudget: CPUTimeBudgetPool

    /// Times the render pass after each frame's scheduled work while any link runs (nil in tests).
    private var renderPasses: RenderPassMeter?
    /// The next vsync after the last link frame of any scheduler (`CLOCK_UPTIME_RAW` nanoseconds),
    /// until that frame's render pass ends: a short idle period may run before it.
    private var nextVsyncNanos: UInt64?
    /// Whether a scheduler other than ``frames`` has a display link (window animations).
    private var otherLinksRunning: Bool
    private var otherLinksSubscription: FrameLinksSubscription?
    /// The posted work's class queues (MainWorkScheduler+Post.swift).
    var posting = Posting()
    /// Classed visible, automation and background work held until the input's frame commits
    /// (MainWorkScheduler+Classed.swift).
    var classedHold = ClassedHold()
    /// Whether classed work that is not input or frame waits now: the app's ``MainJobGateSwitch``
    /// (``follow(_:)``); never without one. Tests set it.
    var holdsClassedWork: @MainActor () -> Bool = { false }
    /// Arms the held classed work's one-refresh deadline; nil: a precise entry on ``wakeUps``. Tests set it.
    var armClassedDeadline: ClassedDeadlineArm?
    /// Ticks the link while an input response is open (``MainFrameBudget/noteDiscreteInput(expectsFrame:)``
    /// asks for it), so the tick render that closes the response comes even while no budgeted
    /// client has work.
    private let inputResponseTick: FrameClient
    /// The after-commit placement's batch: the tick whose budgeted batch waits for its turn after the
    /// tick's commit (nil: none waits), the turn it runs in, and a test's own turns (nil: the app's).
    private var pendingBatch: FrameTick?
    private lazy var budgetTurn = AfterFrameCommitTurn { [weak self] in self?.runBudgetTurn() }
    var budgetTurns: TurnPerformer?

    /// - Parameters:
    ///   - budget: The app's budget (the app: ``SessionInputPending`` input and signposts on).
    ///     The render pass (layout, display, the Core Animation commit) is timed on the main run loop
    ///     while a display link runs and, while this scheduler ticks on its link, charged to the budget
    ///     (``MainFrameBudget/noteRenderPass(nanos:)``): it is the source of the commit estimate
    ///     (``MainCommitMeter``) that ends each frame's budgeted work before the tick's
    ///     `targetTimestamp`, and the charge on a frame with no target. Idle periods use an unposted
    ///     precise run-loop timer; a long one waits until no scheduler's display link runs
    ///     (`displays`' ``DisplayClock/unbudgetedLinks``).
    ///   - displays: The composition root's display clock, which it shares with ``FrameScheduler/app``
    ///     and the windows (``FrameScheduler/install(displays:energy:)``).
    ///   - startup: The launch's phases. The app's composition root passes a launching phase
    ///     (``StartupPhase/init(clock:ledger:timing:onHeldAwait:)``) with its reveal and references
    ///     wired; the default is settled, so a scheduler made after launch holds nothing.
    ///   - wakeUps: The main thread's one deadline queue, when the composition root made it first (the app's
    ///     `main()` makes it before the main-thread watchdog, whose busy windows end on it); its energy source is
    ///     this scheduler's ``energy``. Nil makes one on a new source.
    public convenience init(budget: MainFrameBudget, displays: DisplayClock, startup: StartupPhase = .settled(),
                            wakeUps: MainWakeUpQueue? = nil) {
        self.init(budget: budget, frames: FrameScheduler(name: "budgeted", host: .screen, displays: displays, budget: budget),
                  startup: startup, idleTimer: MainRunLoopPreciseTimer(), ledger: .shared, otherLinks: displays.unbudgetedLinks,
                  measuresRenderPasses: true, sharedWakeUps: wakeUps)
    }

    /// A scheduler on a display clock of its own (tests and fixtures; the app passes its one clock),
    /// so two of them never tick each other.
    public convenience init(budget: MainFrameBudget, startup: StartupPhase = .settled()) {
        self.init(budget: budget, displays: DisplayClock(), startup: startup)
    }

    private init(budget: MainFrameBudget, frames: FrameScheduler, startup: StartupPhase, idleTimer: any IdlePeriodTimer,
                 ledger: WakeupLedger, otherLinks: any OtherFrameLinks, measuresRenderPasses: Bool, sharedWakeUps: MainWakeUpQueue? = nil) {
        self.budget = budget
        board = budget.board
        self.frames = frames
        self.startup = startup
        causes = ObservationCauses(budget: budget)
        planApplies = PlanApplyTurn(turns: budget.turns)
        let wakeUps = sharedWakeUps ?? MainWakeUpQueue(energy: EnergyPolicySource())
        let energy = wakeUps.energy
        self.energy = energy
        self.wakeUps = wakeUps
        otherLinksRunning = otherLinks.anyRunning
        idle = IdleScheduler(budget: budget, timer: idleTimer, ledger: ledger, otherLinksRunning: otherLinks.anyRunning)
        hiddenBudget = CPUTimeBudgetPool(uptimeNanos: budget.uptimeNanos)
        // Its own ambient clients follow the policy it owns, like the app's and the windows' (FrameScheduler+Energy.swift).
        frames.follow(energy)
        // frame-client: one tick while the input-response pass is open (the budget is main state); key to frame
        inputResponseTick = FrameClient(owner: "MainFrameBudget.inputResponse", isAnimation: false, rate: .motion, on: frames) { [weak budget] _ in
            budget?.isInputResponseOpen ?? false
        }
        if measuresRenderPasses {
            renderPasses = RenderPassMeter { [weak self] nanos in self?.renderPassEnded(nanos: nanos) }
        }
        budget.requestTick = { [weak self] in self?.inputResponseTick.activate() }
        if budget.placement == .afterCommit { frames.defersBudgeted = { [weak self] tick in self?.deferBudgeted(tick) } }
        // Its display's ticks own the budget's window while it is subscribed; an idle app times no pass.
        frames.onLinkChange = { [weak self] exists in
            guard let self else { return }
            self.budget.tickOwnsWindow = exists
            self.updateRenderPassMeter()
            self.idle.framesChanged(running: exists)
        }
        frames.onLinkFrame = { [weak self] timestamp, refreshInterval in self?.linkFrame(timestamp: timestamp, refreshInterval: refreshInterval) }
        let subscription = FrameLinksSubscription(changed: { [weak self] running in
            guard let self else { return }
            self.otherLinksRunning = running
            self.updateRenderPassMeter()
            self.idle.otherLinksChanged(running: running)
        }, frame: { [weak self] timestamp, refreshInterval in
            self?.linkFrame(timestamp: timestamp, refreshInterval: refreshInterval)
        })
        otherLinksSubscription = subscription
        otherLinks.add(subscription)
        idle.promote = { [weak self] owner, site, body in self?.post(.background, owner: owner, site: site, body) }
        idle.hiddenWake = { [weak self] in self?.hiddenWake }
        idle.higherWorkPending = { [weak self] in
            guard let self else { return false }
            return self.posting.turnQueued || self.frames.hasBudgetedWork
        }
        // Idle work waits for the launch to settle; the settle reschedules it.
        idle.admitted = { [startup] in startup.admits(.idle) }
        startup.whenReached(.settled) { [weak idle = self.idle] in idle?.reschedule() }
        updateRenderPassMeter()
        // The gate's test runs (`CMUX_MAIN_EXECUTOR_HOOK=1 swift test`): the process's first scheduler installs it.
        if MainExecutorHook.launchEnvironmentAsks { installMainExecutorHook(requested: true) }
    }

    /// A scheduler on a fake link of its own display clock (tests): frames fire only through
    /// ``frameDidFire(timestamp:refreshInterval:targetTimestamp:)``,
    /// and render passes reach the budget and the idle scheduler only through ``renderPassEnded(nanos:)``
    /// (or ``MainFrameBudget/noteRenderPass(nanos:)`` directly); a budget with no passes keeps the
    /// fixed per-frame limit (no deadline without history).
    ///
    /// - Parameters:
    ///   - budget: The budget (tests inject its clock and input source).
    ///   - clock: The stall deadline's clock.
    ///   - ledger: Where frames and idle period timer fires are recorded.
    ///   - startup: The launch's phases (default: already settled, so no class is held).
    ///   - mediaTime: The display clock's time (`CACurrentMediaTime`), when a tick runs: a test that
    ///     fires made-up timestamps with render-pass history passes one in step with them, or the
    ///     budget reads its ticks as late.
    ///   - performTurn: Queues the posted work's run loop turns (``post(_:owner:file:line:_:)``); nil:
    ///     the main run loop's (``MainRunLoopBlock``). A test that runs the turns itself passes its queue.
    ///   - budgetTurns: Queues the after-commit placement's budget turns; nil: the app's
    ///     (``AfterFrameCommitTurn``). A test that runs them itself passes its queue.
    ///   - idleTimer: The idle period timer (tests: a fake fired by hand).
    ///   - otherLinks: The other schedulers' display links (hold long idle periods; their frames
    ///     open short ones). The default has none.
    ///   - makeLink: Makes the fake link.
    public static func testing(budget: MainFrameBudget = MainFrameBudget(), clock: any Clock<Duration> = ContinuousClock(),
                               ledger: WakeupLedger = .shared, startup: StartupPhase = .settled(),
                               mediaTime: @escaping @MainActor () -> CFTimeInterval = { CACurrentMediaTime() },
                               performTurn: TurnPerformer? = nil, budgetTurns: TurnPerformer? = nil,
                               idleTimer: any IdlePeriodTimer = MainRunLoopPreciseTimer(),
                               otherLinks: any OtherFrameLinks = UnbudgetedFrameLinks(),
                               makeLink: @escaping FrameScheduler.LinkFactory) -> MainWorkScheduler {
        let work = MainWorkScheduler(budget: budget, frames: FrameScheduler.testing(name: "budgeted test", clock: clock, ledger: ledger,
                                                                                    mediaTime: mediaTime, budget: budget,
                                                                                    makeLink: makeLink),
                                     startup: startup, idleTimer: idleTimer, ledger: ledger, otherLinks: otherLinks,
                                     measuresRenderPasses: false)
        if let performTurn { work.posting.performTurn = performTurn }
        work.budgetTurns = budgetTurns
        return work
    }

    /// A discrete input (a key-down, a mouse-down, `debug.key`) finished its dispatch; the App's
    /// `InputDispatchContext` calls it once per input. With `expectsFrame`, automation, background and
    /// idle work wait for the render pass of the link's next tick (``MainFrameBudget/noteDiscreteInput(expectsFrame:)``).
    ///
    /// - Parameter expectsFrame: The input's turn changed something the next frame shows.
    public func noteDiscreteInput(expectsFrame: Bool) {
        budget.noteDiscreteInput(expectsFrame: expectsFrame)
    }

    /// A discrete input's dispatch began or ended (``MainFrameBudget/noteDiscreteDispatch(began:)``);
    /// the App's `InputDispatchContext` calls it around each one.
    public func noteDiscreteDispatch(began: Bool) {
        budget.noteDiscreteDispatch(began: began)
        mainExecutorHook?.noteInputTurn(began: began)
    }

    /// Runs main-actor jobs by their task's priority (``MainExecutorHook``), yielding to the person's pending input
    /// as this scheduler's budgeted classes do. The composition root calls it once with the feature's value
    /// (``MainExecutorHook/isRequested(feature:environment:)``); a second call returns the first one's state.
    ///
    /// - Parameter requested: The launch asks for the hook; false installs nothing (``MainExecutorHook/State/off``).
    /// - Returns: What the install found.
    @discardableResult
    public func installMainExecutorHook(requested: Bool) -> MainExecutorHook.State {
        guard requested, mainExecutorHookState == .off else { return mainExecutorHookState }
        let hook = MainExecutorHook(yieldsToInput: { [weak budget] in
            guard let budget else { return false }
            return Self.inputPendingNow(budget)
        })
        mainExecutorHookState = hook.install()
        if mainExecutorHookState == .installed { mainExecutorHook = hook }
        return mainExecutorHookState
    }

    /// Whether a person's input waits now: an injected key at the head of its connection, or input the window
    /// server generated that AppKit has not dispatched (the budget's own check, without its per-frame counters).
    private static func inputPendingNow(_ budget: MainFrameBudget) -> Bool {
        budget.board.pendingInputCount > 0 || budget.pendingInput.hasPendingInput(uptime: Double(budget.nowNanos) / 1_000_000_000)
    }

    /// One display frame (tests call it directly; in the app the display's link ticks).
    /// `targetTimestamp`: when it is shown.
    public func frameDidFire(timestamp: CFTimeInterval? = nil, refreshInterval: Double? = nil,
                             targetTimestamp: CFTimeInterval? = nil) {
        frames.frameDidFire(timestamp: timestamp, refreshInterval: refreshInterval, targetTimestamp: targetTimestamp)
    }

    /// One render pass of the main run loop ended (the ``RenderPassMeter``; tests call it after
    /// ``frameDidFire(timestamp:refreshInterval:targetTimestamp:)``). While this scheduler ticks on its
    /// link it is charged to the next frame and ends the input response when a link tick began after
    /// the latest frame-expecting input (``MainFrameBudget/noteRenderPass(nanos:)``); when it followed
    /// a link frame of any scheduler, a short idle period may run until 1 ms before the next vsync.
    ///
    /// - Parameter nanos: The pass's length.
    public func renderPassEnded(nanos: UInt64) {
        if frames.hasLink { budget.noteRenderPass(nanos: nanos) }
        // A tick whose batch waits for its own turn: the short idle period comes after that turn's pass.
        guard let vsync = nextVsyncNanos, pendingBatch == nil else { return }
        nextVsyncNanos = nil
        idle.frameRendered(nextVsyncNanos: vsync, budgetedWorkHeld: frames.hasBudgetedWork)
    }

    /// Whether a tick's budgeted batch waits for its turn after the tick's commit (after-commit placement).
    var isBudgetTurnPending: Bool { pendingBatch != nil }

    /// The after-commit placement takes a tick's budgeted batch out of the tick: with budgeted work
    /// queued, it asks for one turn after the tick's commit, which runs the newest tick's batch.
    private func deferBudgeted(_ tick: FrameTick) {
        guard frames.hasBudgetedWork else { return }
        let requested = pendingBatch != nil
        pendingBatch = tick
        guard !requested else { return }
        if let budgetTurns { budgetTurns { [weak self] in self?.runBudgetTurn() } } else { budgetTurn.request() }
    }

    /// The budget turn: the waiting tick's batch, in class order and under the budget, whose deadline
    /// (the next vsync less the commit estimate) the tick placed (``MainFrameBudget/beginBudgetTurn()``).
    private func runBudgetTurn() {
        guard let tick = pendingBatch else { return }
        pendingBatch = nil
        budget.beginBudgetTurn()
        frames.runBudgeted(tick)
        budget.endBudgetTurn()
    }

    /// A link frame of any scheduler: the earliest next vsync bounds the short idle period after
    /// this pass.
    private func linkFrame(timestamp: CFTimeInterval, refreshInterval: Double) {
        // CACurrentMediaTime's timebase is CLOCK_UPTIME_RAW's, in seconds.
        let vsync = UInt64(max(0, timestamp + refreshInterval) * 1_000_000_000)
        nextVsyncNanos = min(nextVsyncNanos ?? vsync, vsync)
    }

    /// Render passes are timed while any display link runs; an idle app runs no observer.
    private func updateRenderPassMeter() {
        if frames.hasLink || otherLinksRunning {
            renderPasses?.start()
        } else {
            renderPasses?.stop()
            nextVsyncNanos = nil
        }
    }

    /// Queues `body` for the main thread's idle time (``MainWorkClass/idle``): a long idle period
    /// after 50 ms of quiet, or a short one between a frame's render pass and the next vsync. It
    /// gets the period's ``IdleDeadline``; pending input or higher-class work ends the period, and a
    /// task posted from an idle task waits for the next one. Never inline.
    ///
    /// - Parameters:
    ///   - owner: The task's owner in the board, the watchdog's records and signposts.
    ///   - maxDelay: When set, a task that has not run by then runs as ``MainWorkClass/background``
    ///     work with ``IdleDeadline/didTimeout`` set, by the node's rules for background work (held
    ///     while it is not visible, run at hidden wakes or on show). Nil (the default): it waits for
    ///     idle time.
    ///   - node: The node of the thing the task is for: its periods stop 10 s after the node is
    ///     hidden (not occluded) and resume on show; the task is dropped when the node is released.
    ///   - file: The posting file (leave the default).
    ///   - line: The posting line (leave the default).
    ///   - body: The task.
    public func postIdle(owner: String, maxDelay: Duration? = nil, node: VisibilityNode? = nil, file: StaticString = #fileID,
                         line: UInt = #line, _ body: @escaping @MainActor (IdleDeadline) -> Void) {
        idle.post(owner: taskOwner(owner), site: MainPostSite(file: file, line: line), maxDelay: maxDelay, node: node, body)
    }

    /// ``postIdle(owner:maxDelay:node:file:line:_:)`` with an owner already interned on this
    /// scheduler's board (``MainTaskBoard/owner(_:)``).
    public func postIdle(owner: MainTaskOwner, maxDelay: Duration? = nil, node: VisibilityNode? = nil, file: StaticString = #fileID,
                         line: UInt = #line, _ body: @escaping @MainActor (IdleDeadline) -> Void) {
        idle.post(owner: owner, site: MainPostSite(file: file, line: line), maxDelay: maxDelay, node: node, body)
    }
}
