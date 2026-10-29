import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// The one owner of launch order (plans/cmux-next/chrome-parity/p08-startup.md, section 3B): every
/// launch task is posted here with a ``StartupPriority``, a name and a destination, and runs when
/// its priority allows.
///
/// Chrome's model (chrome/browser/after_startup_task_utils.cc, content/browser/scheduler/browser_task_queues.h):
/// - ``StartupPriority/critical`` runs at once; its name is checked against the critical allowlist
///   and any other name is recorded as a violation.
/// - ``StartupPriority/afterFirstFrame`` waits for ``firstFrameCommitted()``, then runs in post order:
///   on main at ``MainWorkClass/visible`` (budgeted, behind input), on a lane at its priority.
/// - ``StartupPriority/afterStartup`` waits for completion, then is released in post order: on main
///   at ``MainWorkClass/background``, one task per frame and behind pending input; on a lane at its
///   priority.
/// - Completion is a ref count, as in Chrome: the implicit registration ref (``finishRegistration()``),
///   the first-frame ref (``firstFrameCommitted()``, or ``firstFrameMissed(_:)`` when the caller knows
///   none will come), the launch-phase ref (below) and every
///   ``hold(_:)``. When the last one is released the completion is posted to a later main turn, which
///   checks again; the failsafe completes it with reason `failsafe` whatever is still held. The
///   completion never fires after ``beginQuit()``.
/// - One launch, one completion: the scheduler reads the ``StartupPhase`` of its `mainWork`
///   (p06-scheduler). While that phase is not settled, its settle is one more ref, and the phase's
///   settle failsafe (10 s from launch) is the scheduler's failsafe: no afterStartup task runs before
///   the classes the settle opens, and one deadline and one reason end the launch. The settle is no
///   reason of its own: its ref ends with the reason of the ref released before it (a pane's, the
///   restore's, the daemon's), or `failsafe`. The phase's restore and visible-page references are
///   marked by the owner of this scheduler's restore and pane refs (`VisiblePaneRefs`, task 013).
///   Only a scheduler whose phase is already settled (made after launch, tests) arms its own failsafe
///   (``failsafeTimeout``, a ``DemandTimer``), which exists only until completion or ``beginQuit()``.
/// - A post from another thread hops to main at ``WorkPriority/userVisible`` and is queued once there;
///   a lane post after completion goes straight to its lane.
/// - After completion a post goes straight to its class. After ``beginQuit()`` nothing runs.
///
/// Every task is a `launch.startup_task` signpost interval (and trace ring slice) and a ``StartupTaskLog``
/// record, and a main task is the watchdog's current task while it runs.
///
/// One instance per app, made in `main()` and passed by init; tests build their own.
///
/// ```swift
/// let startup = StartupScheduler(mainWork: mainWork, background: work, clock: ContinuousClock())
/// startup.post(.critical, "Theme.apply", on: .main) { theme.apply() }
/// startup.post(.afterStartup, "Launch.cleanup", on: .lane(.files, .idle)) { cleanup.run() }
/// let restore = startup.hold("WindowManager.restore")
/// startup.finishRegistration()
/// ```
@MainActor
public final class StartupScheduler {
    /// How long startup may take before the scheduler's own failsafe completes it (when its launch phase
    /// was settled at init; else the phase's equal settle failsafe is the deadline). Chrome uses 3 min;
    /// cmux panes are local, so a launch not complete in 10 s is a stuck daemon or a bug (p08-startup.md, 3A).
    public nonisolated static let failsafeTimeout: Duration = .seconds(10)

    /// The names a ``StartupPriority/critical`` post may have, in launch order: the critical rows of
    /// plans/cmux-next/startup-DESIGN.md (section 1), which says why the first frame needs each. At most
    /// 15; a new name needs a row there with its measured cost.
    public nonisolated static let criticalAllowlist: [StaticString] = [
        "Settings.takeLaunchRead",
        "ThemeBridge.start",
        "AppActions.bind",
        "Settings.applyManagedFeaturesNow",
        "ManagedPolicyBridge.start",
        "TerminalTheme.follow",
        "Themes.start",
        "MainMenu.make",
        "WindowActivation.activateApp",
        "Daemon.start",
        "FeaturePolicyEnforcer.start",
        "WindowManager.restoreWhenLoaded",
        "WebAuthSessionHandler.install",
        "AppleEvents.getURL",
    ]

    /// How startup completed.
    public nonisolated struct Completion: Sendable {
        /// The reason of the last released ref, or `failsafe`.
        public let reason: StartupInProgressRef.Reason
        /// `CLOCK_UPTIME_RAW` nanoseconds at completion.
        public let uptimeNanos: UInt64
        /// The afterStartup tasks held until now (Chrome's `Startup.AfterStartupTaskCount`).
        public let heldTasks: Int
    }

    /// What ran at launch, readable from any thread.
    public nonisolated let log: StartupTaskLog
    /// The completion, once startup completed.
    public private(set) var completion: Completion?
    /// Called with each main task's name as it begins, until completion or quit (the run marker's last task,
    /// Chrome's crash keys name the task a crash ran in, base/task/common/task_annotator.h).
    public var taskStarted: (@MainActor (StaticString) -> Void)?

    private nonisolated let background: BackgroundWork
    private nonisolated let hop: StartupMainHop
    /// Set on main once completion released the held tasks; read by lane posts from other threads.
    private nonisolated let completed = Atomic<Bool>(false)
    /// Set by ``beginQuit()``; read by lane tasks before they start.
    private nonisolated let quitting = Atomic<Bool>(false)
    private let uptimeNanos: @Sendable () -> UInt64
    private nonisolated let allowlist: Set<String>
    private let failsafe: DemandTimer
    private let visibleWork: FrameBatchQueue
    private let idleOwner: MainTaskOwner
    private let mainWork: MainWorkScheduler
    private var firstFrameDone = false
    /// Set by the first ``firstFrameCommitted()``; a missed frame (``firstFrameMissed(_:)``) never sets it.
    private var frameCommitted = false
    /// ``whenFirstFrameCommitted(_:)`` callers, called once at the committed frame.
    private var frameObservers: [@MainActor () -> Void] = []
    private var isQuitting = false
    private var completionPosted = false
    /// Set when the launch phase settled by its failsafe: completion is due whatever is still held.
    private var failsafePassed = false
    private var lastReason: StartupInProgressRef.Reason = .registrationFinished
    /// The refs still held, by ``StartupInProgressRef/id`` (never reused, so a dropped ref stays held).
    private var refs: [UInt64: StaticString] = [:]
    private var lastRefID: UInt64 = 0
    private var registration: StartupInProgressRef?
    private var firstFrame: StartupInProgressRef?
    private var launchPhase: StartupInProgressRef?
    private var heldAfterFirstFrame: [Pending] = []
    private var heldAfterStartup: [Pending] = []
    /// afterStartup main tasks released to the background class, run one per frame from ``idleHead``.
    private var idleTasks: [Pending?] = []
    private var idleHead = 0
    private var observers: [@MainActor (Completion) -> Void] = []
    /// ``whenCompleteFirst(_:)`` observers: they run before ``observers``.
    private var firstObservers: [@MainActor (Completion) -> Void] = []
    /// ``afterFirstFrame()`` callers, resumed when the afterFirstFrame tasks are released or quit begins.
    private var firstFrameWaiters: [OnceContinuation<Void, OnceContinuationError>] = []
    /// Built in init (lazy because its callback captures self).
    // A budgeted client is always motion rate.
    // frame-client: the afterStartup main tasks, one a frame in the background class's budget, then idle
    private lazy var idleClient: FrameClient = FrameClient(owner: "Startup.afterStartup", budgeted: .background, on: mainWork) { [weak self] _, budget in
        self?.runIdleTask(budget) ?? false
    }

    private nonisolated struct Pending: Sendable {
        let name: StaticString
        let priority: StartupPriority
        let record: Int?
        let work: Work
    }

    private nonisolated enum Work: Sendable {
        case main(@MainActor @Sendable () -> Void)
        case lane(StartupDestination.Lane, @Sendable () -> Void)
    }

    /// Makes the scheduler: it waits for the settle of `mainWork`'s launch phase, or arms its own failsafe
    /// when that phase is already settled.
    ///
    /// - Parameters:
    ///   - mainWork: The app's main-thread scheduler (afterFirstFrame and afterStartup main tasks run as its
    ///     batches); its ``MainWorkScheduler/startup`` phase is the launch this scheduler completes with.
    ///   - background: The app's lanes (lane tasks).
    ///   - hop: How off-main posts and the posted completion reach main (the app: ``StartupMainHop/userVisible``).
    ///   - clock: The failsafe's clock.
    ///   - ledger: Where the failsafe's wakeup is recorded.
    ///   - criticalAllowlist: The names a critical post may have.
    ///   - failsafeTimeout: How long until the scheduler's own failsafe completes startup (a settled phase only).
    ///   - log: The records, signposts and the watchdog's current task (the app: on ``Signposter/launch``).
    ///   - uptimeNanos: The clock of ``Completion/uptimeNanos``.
    public init(mainWork: MainWorkScheduler, background: BackgroundWork, hop: StartupMainHop = .userVisible,
                clock: any Clock<Duration>, ledger: WakeupLedger = .shared,
                criticalAllowlist: [StaticString] = StartupScheduler.criticalAllowlist,
                failsafeTimeout: Duration = StartupScheduler.failsafeTimeout,
                log: StartupTaskLog = .signposted(),
                uptimeNanos: @escaping @Sendable () -> UInt64 = WakeupLedger.systemUptime) {
        self.mainWork = mainWork
        self.background = background
        self.hop = hop
        self.log = log
        self.uptimeNanos = uptimeNanos
        allowlist = Set(criticalAllowlist.map(\.description))
        // timer-class-allow: the settle failsafe, an unposted scheduler timer (p06 section A)
        failsafe = DemandTimer(owner: "StartupScheduler.failsafe", clock: clock, ledger: ledger)
        visibleWork = FrameBatchQueue(owner: "Startup.afterFirstFrame", budgeted: .visible, on: mainWork)
        idleOwner = mainWork.budget.board.owner("Startup.afterStartup")
        registration = hold("Startup.registration")
        firstFrame = hold("Startup.firstFrame")
        let phase = mainWork.startup
        if phase.phase < .settled {
            launchPhase = hold("Startup.launchPhase")
            phase.whenReached(.settled) { [weak self, weak phase] in self?.launchPhaseSettled(phase?.settleCause) }
        } else {
            failsafe.scheduleOnMain(after: failsafeTimeout) { [weak self] in self?.failsafeFired() }
        }
    }

    // MARK: Posting

    /// Posts main-thread work. From another thread it hops to main first (and is queued once).
    ///
    /// - Parameters:
    ///   - priority: When it runs.
    ///   - name: Its name in records, signposts and the watchdog (`Domain.step`).
    ///   - destination: `.main`.
    ///   - work: The main-actor work; no file, network or process work.
    public nonisolated func post(_ priority: StartupPriority, _ name: StaticString, on destination: StartupDestination.Main,
                                 _ work: @escaping @MainActor @Sendable () -> Void) {
        hop.onMain { [self] in accept(Pending(name: name, priority: priority, record: nil, work: .main(work))) }
    }

    /// Posts lane work. After completion it goes straight to its lane from any thread; before, a post
    /// from another thread hops to main first (and is queued once).
    ///
    /// - Parameters:
    ///   - priority: When it runs.
    ///   - name: Its name in records and signposts (`Domain.step`).
    ///   - destination: The lane and its priority.
    ///   - work: The blocking work; it runs on a lane thread, never on main.
    public nonisolated func post(_ priority: StartupPriority, _ name: StaticString, on destination: StartupDestination.Lane,
                                 _ work: @escaping @Sendable () -> Void) {
        if completed.load(ordering: .acquiring), !quitting.load(ordering: .acquiring) {
            // After completion no priority is held: record a broken rule, then straight to the lane.
            let record = log.posted(name, priority, destination.destination, violation: violation(priority, name))
            submit(Pending(name: name, priority: Self.running(priority), record: record, work: .lane(destination, work)),
                   destination, work)
            return
        }
        let task = Pending(name: name, priority: priority, record: nil, work: .lane(destination, work))
        hop.onMain { [self] in accept(task) }
    }

    /// Holds startup open until the ref is released.
    ///
    /// - Parameter name: What it waits for (`WindowManager.restore`).
    /// - Returns: The ref; after completion or quit one that holds nothing.
    public func hold(_ name: StaticString) -> StartupInProgressRef {
        guard completion == nil, !isQuitting else { return StartupInProgressRef(name: name, id: 0, scheduler: nil) }
        lastRefID += 1
        let ref = StartupInProgressRef(name: name, id: lastRefID, scheduler: self)
        refs[ref.id] = name
        return ref
    }

    /// The names of the refs still held (`debug.startup`).
    public var heldRefs: [String] { refs.values.map(\.description).sorted() }

    /// The app registered its launch work: releases the implicit registration ref.
    public func finishRegistration() {
        registration?.release(.registrationFinished)
        registration = nil
    }

    /// The first window's first frame was committed: releases the first-frame ref and the held
    /// afterFirstFrame tasks, in post order.
    public func firstFrameCommitted() {
        guard !isQuitting else { return }
        releaseAfterFirstFrame()
        firstFrame?.release(.firstFrameCommitted)
        firstFrame = nil
        guard !frameCommitted else { return }
        frameCommitted = true
        let waiting = frameObservers
        frameObservers = []
        for observer in waiting { observer() }
    }

    /// Calls `body` when the first window's first frame is committed (``firstFrameCommitted()``): now when it
    /// was, never for ``firstFrameMissed(_:)`` and never after ``beginQuit()``. For work that measures the frame
    /// itself, where the afterFirstFrame release at a missed deadline would measure before the frame.
    public func whenFirstFrameCommitted(_ body: @escaping @MainActor () -> Void) {
        if frameCommitted { return body() }
        guard !isQuitting else { return }
        frameObservers.append(body)
    }

    /// No first frame came by the caller's deadline: releases the held afterFirstFrame tasks, so that
    /// work never waits for a frame that may not come, and ends the first-frame ref with `reason` when
    /// the caller knows no frame will come (``StartupInProgressRef/Reason/noWindow``,
    /// ``StartupInProgressRef/Reason/daemonUnavailable``). With nil the ref stays held for a late
    /// ``firstFrameCommitted()`` or the failsafe: a missed deadline is not a committed frame.
    public func firstFrameMissed(_ reason: StartupInProgressRef.Reason?) {
        guard !isQuitting else { return }
        releaseAfterFirstFrame()
        guard let reason else { return }
        firstFrame?.release(reason)
        firstFrame = nil
    }

    /// Quit began: drops every task not started, cancels the failsafe, and runs nothing more.
    public func beginQuit() {
        guard !isQuitting else { return }
        (isQuitting, taskStarted) = (true, nil)
        quitting.store(true, ordering: .releasing)
        log.setPhase(.quitting)
        failsafe.cancel()
        heldAfterFirstFrame = []
        heldAfterStartup = []
        idleTasks = []
        idleHead = 0
        idleClient.deactivate()
        observers = []
        firstObservers = []
        frameObservers = []
        resumeFirstFrameWaiters()
    }

    /// Calls `body` with the completion: now when startup already completed, never after quit.
    public func whenComplete(_ body: @escaping @MainActor (Completion) -> Void) {
        if let completion { return body(completion) }
        guard !isQuitting else { return }
        observers.append(body)
    }

    /// As ``whenComplete(_:)``, but before every ``whenComplete(_:)`` observer: for a launch value that a reader
    /// of the completion's own mark (`LaunchOrder`'s `startup_complete`) must already have on the same pipe.
    public func whenCompleteFirst(_ body: @escaping @MainActor (Completion) -> Void) {
        if let completion { return body(completion) }
        guard !isQuitting else { return }
        firstObservers.append(body)
    }

    /// Returns once the afterFirstFrame tasks are released (the first frame, ``firstFrameMissed(_:)``
    /// or completion): at once when they were, and at once after ``beginQuit()``. For async launch
    /// work that goes on after the first frame (a question shown once a window drew); a post is the
    /// way for work that fits in one main turn.
    public func afterFirstFrame() async {
        guard !firstFrameDone, !isQuitting else { return }
        try? await withOnceContinuation { (done: OnceContinuation<Void, OnceContinuationError>) in firstFrameWaiters.append(done) }
    }

    /// Whether the scheduler's own failsafe deadline is pending (never while its launch phase owns the deadline).
    public var failsafeArmed: Bool { failsafe.isScheduled }

    // MARK: Refs and completion

    func refReleased(_ ref: StartupInProgressRef, reason: StartupInProgressRef.Reason) {
        guard refs.removeValue(forKey: ref.id) != nil else { return }
        lastReason = reason
        guard isDue, completion == nil, !isQuitting, !completionPosted else { return }
        completionPosted = true
        hop.later { [weak self] in self?.completeIfStillDue() }
    }

    /// Every ref is released, or the launch phase's failsafe passed.
    private var isDue: Bool { refs.isEmpty || failsafePassed }

    private func completeIfStillDue() {
        completionPosted = false
        guard isDue, completion == nil, !isQuitting else { return }
        complete(failsafePassed ? .failsafe : lastReason)
    }

    /// The launch phase settled: its ref ends with the last reason (the settle names no reason of its own),
    /// and a failsafe settle ends the launch whatever is held.
    private func launchPhaseSettled(_ cause: StartupPhase.SettleCause?) {
        if cause == .failsafe { failsafePassed = true }
        launchPhase?.release(cause == .failsafe ? .failsafe : lastReason)
        launchPhase = nil
    }

    private func failsafeFired() {
        guard completion == nil, !isQuitting else { return }
        complete(.failsafe)
    }

    private func complete(_ reason: StartupInProgressRef.Reason) {
        failsafe.cancel()
        releaseAfterFirstFrame()
        let held = heldAfterStartup
        heldAfterStartup = []
        let done = Completion(reason: reason, uptimeNanos: uptimeNanos(), heldTasks: held.count)
        (completion, taskStarted) = (done, nil)
        log.setPhase(.complete)
        log.completed(reason, heldTasks: held.count)
        for task in held { dispatch(task) }
        log.close()
        completed.store(true, ordering: .releasing)
        let waiting = firstObservers + observers
        (firstObservers, observers) = ([], [])
        for observer in waiting { observer(done) }
    }

    // MARK: Running

    /// A post on main: recorded, then run, held or released to its class.
    private func accept(_ posted: Pending) {
        guard !isQuitting else { return }
        let destination: StartupDestination = switch posted.work {
        case .main: .main
        case .lane(let lane, _): lane.destination
        }
        let record = log.posted(posted.name, posted.priority, destination, violation: violation(posted.priority, posted.name))
        let task = Pending(name: posted.name, priority: Self.running(posted.priority), record: record, work: posted.work)
        switch task.priority {
        case .afterFirstFrame where !firstFrameDone: heldAfterFirstFrame.append(task)
        case .afterStartup where completion == nil: heldAfterStartup.append(task)
        case .critical, .afterFirstFrame, .afterStartup, .onDemand: dispatch(task)
        }
    }

    /// The rule a post at `priority` named `name` breaks, if any (checked before and after completion).
    private nonisolated func violation(_ priority: StartupPriority, _ name: StaticString) -> StartupTaskLog.Violation? {
        switch priority {
        case .critical: allowlist.contains(name.description) ? nil : .notInCriticalAllowlist
        case .onDemand: .onDemandPosted
        case .afterFirstFrame, .afterStartup: nil
        }
    }

    /// The priority a post runs at: an onDemand post runs as afterStartup.
    private nonisolated static func running(_ priority: StartupPriority) -> StartupPriority {
        priority == .onDemand ? .afterStartup : priority
    }

    private func releaseAfterFirstFrame() {
        guard !firstFrameDone else { return }
        firstFrameDone = true
        log.setPhase(.afterFirstFrame)
        let held = heldAfterFirstFrame
        heldAfterFirstFrame = []
        for task in held { dispatch(task) }
        resumeFirstFrameWaiters()
    }

    private func resumeFirstFrameWaiters() {
        let waiting = firstFrameWaiters
        firstFrameWaiters = []
        for waiter in waiting { waiter.resume(returning: ()) }
    }

    /// Runs `task` now (critical), or hands it to its main class or its lane.
    private func dispatch(_ task: Pending) {
        switch task.work {
        case .lane(let lane, let body):
            submit(task, lane, body)
        case .main(let body):
            switch task.priority {
            case .critical:
                runMain(task, body)
            case .afterFirstFrame:
                visibleWork.enqueue { [weak self] in self?.runMain(task, body) }
            case .afterStartup, .onDemand:
                idleTasks.append(task)
                idleClient.activate()
            }
        }
    }

    private func runMain(_ task: Pending, _ body: @MainActor @Sendable () -> Void) {
        guard !isQuitting else { return }
        taskStarted?(task.name)
        log.run(task.record, task.name, task.priority, onMain: true) { body() }
    }

    /// One afterStartup main task per frame (the frame scheduler fires this only while the background
    /// class may run, so a pending key goes first). True while more are queued.
    private func runIdleTask(_ budget: MainFrameBudget) -> Bool {
        guard idleHead < idleTasks.count, let task = idleTasks[idleHead] else { return false }
        idleTasks[idleHead] = nil
        idleHead += 1
        if idleHead == idleTasks.count {
            idleTasks.removeAll(keepingCapacity: true)
            idleHead = 0
        }
        if case .main(let body) = task.work {
            budget.run(.background, owner: idleOwner) { runMain(task, body) }
        }
        return idleHead < idleTasks.count
    }

    private nonisolated func submit(_ task: Pending, _ lane: StartupDestination.Lane, _ body: @escaping @Sendable () -> Void) {
        let (record, name, priority) = (task.record, task.name, task.priority)
        let run: @Sendable () -> Void = { [self] in
            guard !quitting.load(ordering: .acquiring) else { return }
            log.run(record, name, priority, onMain: false, body)
        }
        guard let sequence = lane.sequence else { return background.post(lane.priority, mayBlock: lane.blockingLane, run) }
        sequence.post(lane.priority, run)
    }
}
