import CmuxNextCompat

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
///   the first-frame ref (``firstFrameCommitted()``) and every ``hold(_:)``. When the last one is
///   released the completion is posted to a later main turn, which checks again; a failsafe
///   (``failsafeTimeout``, a ``DemandTimer``) completes it with reason `failsafe`. The completion
///   never fires after ``beginQuit()``, and its timer exists only before it.
/// - A post from another thread hops to main at ``WorkPriority/userVisible`` and is queued once there;
///   a lane post after completion goes straight to its lane.
/// - After completion a post goes straight to its class. After ``beginQuit()`` nothing runs.
///
/// Every task is a `startup.task` signpost interval and a ``StartupTaskLog`` record, and a main
/// task is the watchdog's current task while it runs.
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
    /// How long startup may take before the failsafe completes it. Chrome uses 3 min; cmux panes are
    /// local, so a launch not complete in 10 s is a stuck daemon or a bug (p08-startup.md, 3A).
    public nonisolated static let failsafeTimeout: Duration = .seconds(10)

    /// The names a ``StartupPriority/critical`` post may have (<= 15; task 015 fills it from the
    /// startup design's table).
    public nonisolated static let criticalAllowlist: [StaticString] = []

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

    private nonisolated let background: BackgroundWork
    private nonisolated let hop: StartupMainHop
    /// Set on main once completion released the held tasks; read by lane posts from other threads.
    private nonisolated let completed = Atomic<Bool>(false)
    /// Set by ``beginQuit()``; read by lane tasks before they start.
    private nonisolated let quitting = Atomic<Bool>(false)
    private let uptimeNanos: @Sendable () -> UInt64
    private let allowlist: Set<String>
    private let failsafe: DemandTimer
    private let visibleWork: FrameBatchQueue
    private let idleOwner: MainTaskOwner
    private let mainWork: MainWorkScheduler
    private var firstFrameDone = false
    private var isQuitting = false
    private var completionPosted = false
    private var lastReason: StartupInProgressRef.Reason = .registrationFinished
    private var refs: [ObjectIdentifier: StaticString] = [:]
    private var registration: StartupInProgressRef?
    private var firstFrame: StartupInProgressRef?
    private var heldAfterFirstFrame: [Pending] = []
    private var heldAfterStartup: [Pending] = []
    /// afterStartup main tasks released to the background class, run one per frame from ``idleHead``.
    private var idleTasks: [Pending?] = []
    private var idleHead = 0
    private var observers: [@MainActor (Completion) -> Void] = []
    /// Built in init (lazy because its callback captures self).
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

    /// Makes the scheduler and arms its failsafe.
    ///
    /// - Parameters:
    ///   - mainWork: The app's main-thread scheduler (afterFirstFrame and afterStartup main tasks run as its batches).
    ///   - background: The app's lanes (lane tasks).
    ///   - hop: How off-main posts and the posted completion reach main (the app: ``StartupMainHop/userVisible``).
    ///   - clock: The failsafe's clock.
    ///   - ledger: Where the failsafe's wakeup is recorded.
    ///   - criticalAllowlist: The names a critical post may have.
    ///   - failsafeTimeout: How long until the failsafe completes startup.
    ///   - log: The records, signposts and the watchdog's current task (the app: signposts on).
    ///   - uptimeNanos: The clock of ``Completion/uptimeNanos``.
    public init(mainWork: MainWorkScheduler, background: BackgroundWork, hop: StartupMainHop = .userVisible,
                clock: any Clock<Duration>, ledger: WakeupLedger = .shared,
                criticalAllowlist: [StaticString] = StartupScheduler.criticalAllowlist,
                failsafeTimeout: Duration = StartupScheduler.failsafeTimeout,
                log: StartupTaskLog = StartupTaskLog(signposts: true),
                uptimeNanos: @escaping @Sendable () -> UInt64 = WakeupLedger.systemUptime) {
        self.mainWork = mainWork
        self.background = background
        self.hop = hop
        self.log = log
        self.uptimeNanos = uptimeNanos
        allowlist = Set(criticalAllowlist.map(\.description))
        failsafe = DemandTimer(owner: "StartupScheduler.failsafe", clock: clock, ledger: ledger)
        visibleWork = FrameBatchQueue(owner: "Startup.afterFirstFrame", budgeted: .visible, on: mainWork)
        idleOwner = mainWork.budget.board.owner("Startup.afterStartup")
        registration = StartupInProgressRef(name: "Startup.registration", scheduler: self)
        firstFrame = StartupInProgressRef(name: "Startup.firstFrame", scheduler: self)
        if let registration { refs[ObjectIdentifier(registration)] = registration.name }
        if let firstFrame { refs[ObjectIdentifier(firstFrame)] = firstFrame.name }
        failsafe.schedule(after: failsafeTimeout) { @MainActor [weak self] in self?.failsafeFired() }
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
        let task = Pending(name: name, priority: priority, record: nil, work: .lane(destination, work))
        if priority != .onDemand, completed.load(ordering: .acquiring), !quitting.load(ordering: .acquiring) {
            submit(task, destination, work)
            return
        }
        hop.onMain { [self] in accept(task) }
    }

    /// Holds startup open until the ref is released.
    ///
    /// - Parameter name: What it waits for (`WindowManager.restore`).
    /// - Returns: The ref; after completion or quit one that holds nothing.
    public func hold(_ name: StaticString) -> StartupInProgressRef {
        guard completion == nil, !isQuitting else { return StartupInProgressRef(name: name, scheduler: nil) }
        let ref = StartupInProgressRef(name: name, scheduler: self)
        refs[ObjectIdentifier(ref)] = name
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
    }

    /// Quit began: drops every task not started, cancels the failsafe, and runs nothing more.
    public func beginQuit() {
        guard !isQuitting else { return }
        isQuitting = true
        quitting.store(true, ordering: .releasing)
        log.setPhase(.quitting)
        failsafe.cancel()
        heldAfterFirstFrame = []
        heldAfterStartup = []
        idleTasks = []
        idleHead = 0
        idleClient.deactivate()
        observers = []
    }

    /// Calls `body` with the completion: now when startup already completed, never after quit.
    public func whenComplete(_ body: @escaping @MainActor (Completion) -> Void) {
        if let completion { return body(completion) }
        guard !isQuitting else { return }
        observers.append(body)
    }

    /// Whether the failsafe deadline is pending.
    public var failsafeArmed: Bool { failsafe.isScheduled }

    // MARK: Refs and completion

    func refReleased(_ ref: StartupInProgressRef, reason: StartupInProgressRef.Reason) {
        guard refs.removeValue(forKey: ObjectIdentifier(ref)) != nil else { return }
        lastReason = reason
        guard refs.isEmpty, completion == nil, !isQuitting, !completionPosted else { return }
        completionPosted = true
        hop.later { [weak self] in self?.completeIfStillDue() }
    }

    private func completeIfStillDue() {
        completionPosted = false
        guard refs.isEmpty, completion == nil, !isQuitting else { return }
        complete(lastReason)
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
        completion = done
        log.setPhase(.complete)
        log.completed(reason)
        for task in held { dispatch(task) }
        log.close()
        completed.store(true, ordering: .releasing)
        let waiting = observers
        observers = []
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
        let violation: StartupTaskLog.Violation? = switch posted.priority {
        case .critical: allowlist.contains(posted.name.description) ? nil : .notInCriticalAllowlist
        case .onDemand: .onDemandPosted
        case .afterFirstFrame, .afterStartup: nil
        }
        let record = log.posted(posted.name, posted.priority, destination, violation: violation)
        let task = Pending(name: posted.name, priority: posted.priority == .onDemand ? .afterStartup : posted.priority,
                           record: record, work: posted.work)
        switch task.priority {
        case .afterFirstFrame where !firstFrameDone: heldAfterFirstFrame.append(task)
        case .afterStartup where completion == nil: heldAfterStartup.append(task)
        case .critical, .afterFirstFrame, .afterStartup, .onDemand: dispatch(task)
        }
    }

    private func releaseAfterFirstFrame() {
        guard !firstFrameDone else { return }
        firstFrameDone = true
        log.setPhase(.afterFirstFrame)
        let held = heldAfterFirstFrame
        heldAfterFirstFrame = []
        for task in held { dispatch(task) }
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
        background.post(lane.priority, mayBlock: lane.blockingLane) { [self] in
            guard !quitting.load(ordering: .acquiring) else { return }
            log.run(record, name, priority, onMain: false, body)
        }
    }
}
