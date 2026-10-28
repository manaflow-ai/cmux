import CmuxNextCompat
public import CmuxNextTrace
import Darwin
import Dispatch
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

/// Runs work that may block off Swift's cooperative pool, on small lanes by kind, at a stated priority.
///
/// This is cmux's version of Chrome's task traits (`base/task/task_traits.h`): every item states its
/// ``WorkPriority`` (TaskPriority), its ``BlockingLane`` (MayBlock, by kind) and its ``ShutdownBehavior``.
/// The cooperative pool has one thread per core, so a file read, a process wait or a `getaddrinfo` there
/// stalls every task behind it; here such work runs on a lane slot instead (a serial `DispatchQueue`
/// at the item's QoS), and the pool stays free for the async work that typing and frames wait for.
///
/// Priority inversion: there is no synchronous wait in this API. Main-actor code either awaits
/// ``run(_:mayBlock:shutdown:fileID:line:_:)`` (the main thread keeps running) or posts with
/// ``post(_:mayBlock:shutdown:fileID:line:_:)``. A caller that awaits work below its own priority boosts it at
/// the call: the item runs at the higher of its priority and the caller's (`Task.currentPriority`).
///
/// Later escalation goes through a handle: ``runHandle(_:mayBlock:shutdown:fileID:line:_:)`` queues an item at
/// its own priority, and ``WorkHandle/raise(to:)`` or an await of ``WorkHandle/value`` (at the awaiter's
/// priority) moves it up while queued, or overrides its slot thread's QoS while it runs (Chrome's
/// `UpdateableSequencedTaskRunner::UpdatePriority` and `ScopedBoostablePriority`). `run` itself boosts only at
/// the call: Swift's escalation hook (`withTaskPriorityEscalationHandler`) is macOS 26 only and strong-linked, so
/// a later waiter of the task that awaits `run` does not reach the item. Work started low that a person may
/// wait for later takes a handle; to keep work low, post it or await it from a low task
/// (`Task(priority: WorkPriority.bestEffort.taskPriority)`).
///
/// Order: items that run at once on a lane are not ordered, the items of one priority neither (the files lane
/// runs several at each priority, ``FilesLaneWidths``). Work that must run in order, writes to one file or one
/// store, goes through one ``sequence(_:mayBlock:)``.
///
/// Startup fence: between ``beginBestEffortFence()`` and ``endBestEffortFence()`` posted
/// ``WorkPriority/idle`` and ``WorkPriority/bestEffort`` items wait, so they do not compete with launch.
/// An awaited item is never held: someone waits for it, so it runs at once at its own priority. The app
/// raises it once, with no cap, through ``raiseLaunchFence(cap:clock:)``, and lowers it at ``StartupPhase``'s
/// reveal (``LaunchFence``).
///
/// Every lane item is traced from its `fileID` and `line` post to its run (``TaskTrace``, Chrome's `TaskAnnotator`).
///
/// One instance per app, built in the composition root (AppServices) and passed through `init`;
/// tests build their own.
///
/// ```swift
/// let data = try await work.run(.userVisible, mayBlock: .files) { permit in try Data(blockingContentsOf: url, permit) }
/// work.post(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) { permit in try? data.blockingWrite(to: url, permit, options: .atomic) }
/// let addresses = try await work.run(.userBlocking, mayBlock: .system) { resolve(host) }
/// let saves = work.sequence("journal")  // in order, one at a time, on any files slot
/// saves.post(.bestEffort, shutdown: .blockShutdown) { try? journal.append(entry) }
/// // Main-actor callers: the result comes back as a posted, attributed main task (PostTaskAndReply).
/// work.run(.userVisible, mayBlock: .files) { parse(url) }
///     .reply(on: mainWork, class: .visible, owner: "preview.load") { preview.show($0) }
/// let page = work.task(.userVisible) { try await fetch(url) }  // async work, no blocking call
/// ```
///
/// Shutdown, as Chrome's `TaskTracker` (`base/task/thread_pool/task_tracker.cc`): ``beginShutdown()`` drops
/// or cancels ``ShutdownBehavior/skipOnShutdown`` items, drops ``ShutdownBehavior/continueOnShutdown`` ones
/// that have not started (started ones run on), and refuses new items other than
/// ``ShutdownBehavior/blockShutdown`` ones; ``shutdown()`` then returns when every block-shutdown item, lane
/// item or ``task(_:shutdown:fileID:line:_:)``, has finished. After that, a block-shutdown item is refused too
/// (Chrome DCHECKs such a post): nothing would wait for it, and Debug records its site.
///
/// Quit waits for block-shutdown lane items, so shutdown raises them, as Chrome runs BLOCK_SHUTDOWN tasks at a
/// normal thread priority once shutdown starts: a queued one, and one submitted later, starts at `.userInitiated`,
/// and a running one below that gets one `.userInitiated` override on its thread until it ends. On
/// ``BlockingLane/files`` a block-shutdown item keeps its level's slots, so each level keeps its width and post
/// order (on a level one slot wide a later save never overtakes an earlier one) and the levels still run side by
/// side. A block-shutdown
/// ``task(_:shutdown:fileID:line:_:)`` keeps its priority: raising a running Swift task needs
/// `Task.escalatePriority`, which macOS 14 and 15 lack (see the escalation note above).
public final class BackgroundWork: Sendable {
    /// How many ``BlockingLane/cpu`` items run at once.
    public let cpuWidth: Int
    /// How many ``BlockingLane/files`` items of each priority run at once.
    public let filesWidths: FilesLaneWidths
    /// The label prefix of every lane slot's dispatch queue (`<label>.<lane>.<priority or slot>`).
    public let label: String
    /// One scheduler per ``BlockingLane``, by `rawValue`.
    let lanes: [LaneScheduler]
    let onQueued: @Sendable (BlockingLane, WorkPriority) -> Void
    private let onRan: (@Sendable (BlockingLane, WorkPriority, UInt64, UInt64) -> Void)?
    /// False after ``stopReportingRuns()``: items submitted later skip `onRan`.
    private let reportsRuns = Atomic<Bool>(true)
    /// The clock a block-shutdown task's run time is measured with (``blockShutdownLimit``); the lanes stamp their
    /// items with it too.
    let uptimeNanos: @Sendable () -> UInt64
    // concurrency-allow: id counter, the shutdown count and the registered tasks, read and written synchronously by submitters, lane threads and finishing tasks (lock carve-out: counters and a dictionary, no I/O under it).
    let state = Mutex(DrainState())
    /// Test seams around a ``task(_:shutdown:fileID:line:_:)`` start; production uses ``TaskHooks/none``.
    let taskHooks: TaskHooks
    /// The main-thread task board whose open input work makes an awaited low item a priority-inversion site.
    let inputTurns: MainTaskBoard?
    /// Traces each lane item's post; its run's flow-in goes in the lane's `task.run` slice.
    let taskTrace: TaskTrace

    struct DrainState {
        var nextID: UInt64 = 1
        /// Block-shutdown items (lane items and tasks) that have not finished.
        var blocking = 0
        var waiters: [OnceContinuation<Void, OnceContinuationError>] = []
        /// ``beginShutdown()`` ran: only block-shutdown items are taken.
        var closed = false
        /// ``shutdown()`` has returned: no item is taken, a block-shutdown one neither.
        var drained = false
        /// The ``task(_:shutdown:fileID:line:_:)`` tasks that have not finished, by id.
        var tasks: [UInt64: RegisteredTask] = [:]
        /// Block-shutdown items that ran longer than ``blockShutdownLimit``, oldest first, at most
        /// ``overrunLimit``.
        var overruns: [BlockShutdownOverrun] = []
        /// Sites that posted a block-shutdown item after ``shutdown()`` returned, oldest first, at most
        /// ``overrunLimit``.
        var latePosts: [String] = []
        /// The cap timer of each raised ``LaunchFence``, by fence; ``beginShutdown()`` cancels them.
        var launchCaps: [ObjectIdentifier: DemandTimer] = [:]

        mutating func takeID() -> UInt64 {
            defer { nextID += 1 }
            return nextID
        }
    }

    /// Creates the lanes.
    ///
    /// - Parameters:
    ///   - cpuWidth: how many ``BlockingLane/cpu`` items run at once; default ``defaultCPUWidth``.
    ///   - filesWidths: how many ``BlockingLane/files`` items of each priority run at once; default
    ///     ``FilesLaneWidths/standard``. Tests that hold a slot so that the next item queues pass
    ///     ``FilesLaneWidths/serial``.
    ///   - label: the dispatch queue label prefix, which shows in traces and crash reports.
    ///   - onQueued: called with the lane and the priority each time an item has to wait for a slot (it
    ///     did not start at once), after it is queued and before it can start; default nothing. Traces
    ///     count waits with it; tests use it as the point after which a cancel or an escalation meets a
    ///     queued item, not the checks at the call.
    ///   - hangs: watches each item's run on its lane thread for a hang, with the lane's
    ///     ``hangDeadline(_:)``; the wait for a slot is not watched. nil (the default) watches nothing.
    ///   - onRan: called on the lane thread after each item ran, with its lane, its priority and its start
    ///     and end in `uptimeNanos` nanoseconds (the stamps the lane takes for its stats: no extra clock read);
    ///     default none. The startup trace (CmuxNextLaunch's StartupTrace) records lane jobs with it until it
    ///     closes (``stopReportingRuns()``).
    ///   - uptimeNanos: the clock every item's queue wait and run time (``laneTimes(resetting:)``, `onRan`, a
    ///     block-shutdown item's run) are measured with, in nanoseconds: three reads per lane item; nil is
    ///     `CLOCK_UPTIME_RAW`. Tests pass their own.
    ///   - inputTurns: the app's main task board; an item below `.userBlocking` awaited on main while it runs input
    ///     work is a Debug priority-inversion site. nil checks nothing.
    ///   - trace: the runtime of each lane item's ``TaskTrace`` records and `task.run` slices; default the process's.
    public convenience init(cpuWidth: Int = BackgroundWork.defaultCPUWidth, filesWidths: FilesLaneWidths = .standard,
                            label: String = "com.cmuxterm.next.work",
                            hangs: (any HangWatchScoping)? = nil,
                            onQueued: @escaping @Sendable (BlockingLane, WorkPriority) -> Void = { _, _ in },
                            onRan: (@Sendable (BlockingLane, WorkPriority, UInt64, UInt64) -> Void)? = nil,
                            uptimeNanos: (@Sendable () -> UInt64)? = nil, inputTurns: MainTaskBoard? = nil,
                            trace: TraceRuntime = .shared) {
        self.init(cpuWidth: cpuWidth, filesWidths: filesWidths, label: label, hangs: hangs, onQueued: onQueued,
                  onRan: onRan, uptimeNanos: uptimeNanos, taskHooks: .none, inputTurns: inputTurns, trace: trace)
    }

    /// The designated init; tests pass ``TaskHooks`` to stop a task between its steps, the clock of the
    /// system lane's ``mayBlockThreshold``, a ``ThreadQoSOverride`` that counts the overrides a raise or
    /// shutdown puts on running items, and the trace runtime the lanes' `task.run` slices go to.
    init(cpuWidth: Int, filesWidths: FilesLaneWidths = .standard, label: String, hangs: (any HangWatchScoping)? = nil,
         onQueued: @escaping @Sendable (BlockingLane, WorkPriority) -> Void,
         onRan: (@Sendable (BlockingLane, WorkPriority, UInt64, UInt64) -> Void)? = nil,
         uptimeNanos: (@Sendable () -> UInt64)?, taskHooks: TaskHooks,
         mayBlockClock: any Clock<Duration> = ContinuousClock(), qosOverride: ThreadQoSOverride = .system,
         inputTurns: MainTaskBoard? = nil, trace: TraceRuntime = .shared) {
        self.taskHooks = taskHooks
        self.inputTurns = inputTurns
        taskTrace = TaskTrace(runtime: trace)
        self.cpuWidth = max(1, cpuWidth)
        self.filesWidths = filesWidths
        self.label = label
        self.onQueued = onQueued
        self.onRan = onRan
        let clock: @Sendable () -> UInt64 = uptimeNanos ?? { LaneStats.uptimeNanos() }
        self.uptimeNanos = clock
        lanes = BlockingLane.allCases.map { lane in
            let traits: (policy: LaneScheduler.Policy, mayBlock: Bool, caps: [LaneCap: Int]) = switch lane {
            case .files: (.perPriority(widths: WorkPriority.allCases.map(filesWidths.width)), true, [:])
            case .system: (.shared(width: Self.systemWidth, reserved: Self.systemReserved), true, [.hostResolution: Self.hostResolutionCap])
            // The .cpu lane is sized to the cores: a blocking seam in one of its items is a wrong-lane violation.
            case .cpu: (.shared(width: max(1, cpuWidth)), false, [:])
            }
            // One registration per slot: items of a lane run at once, and a hang scope nests only on one thread.
            let watching = hangs.map { LaneScheduler.HangWatching(name: Self.hangScopeName(lane), deadline: Self.hangDeadline(lane), watch: $0) }
            // Only the system lane is shared and may block; the files lane's per-level widths bound its low items.
            let compensation = lane == .system
                ? LaneScheduler.MayBlockCompensation(threshold: Self.mayBlockThreshold, clock: mayBlockClock) : nil
            return LaneScheduler(label: "\(label).\(lane)", policy: traits.policy, mayBlock: traits.mayBlock, caps: traits.caps,
                                 compensation: compensation, hangWatching: watching, qosOverride: qosOverride,
                                 clock: clock, lane: lane, trace: trace)
        }
    }

    /// Every lane's queue wait and run time per priority since launch or the last reset, lane by lane and highest
    /// priority first (`debug.work`). Present in every build.
    ///
    /// - Parameter resetting: also zero them, in the same read: each counter is taken with one atomic exchange, so
    ///   an item that ran during the read counts in this read or in the next, never in neither.
    public func laneTimes(resetting: Bool = false) -> [LaneTimes] {
        BlockingLane.allCases.flatMap { lanes[$0.rawValue].stats.snapshot(lane: $0, resetting: resetting) }
    }

    /// The longest queue-wait p99 of ``WorkPriority/userBlocking`` items over the lanes, in nanoseconds: how long the
    /// work a person waits for sat behind other work (RUN-13 wants at most 2 ms). 0 before any such item ran. A hang
    /// report's coarse counts carry it (CmuxNextApp's `WatchdogReporting.counts`).
    public var userBlockingQueueWaitP99Nanos: UInt64 {
        Self.userBlockingQueueWaitP99Nanos(in: laneTimes())
    }

    /// ``userBlockingQueueWaitP99Nanos`` of one ``laneTimes(resetting:)`` read, so a report that shows the lanes
    /// shows a p99 from the same read.
    public static func userBlockingQueueWaitP99Nanos(in times: [LaneTimes]) -> UInt64 {
        times.filter { $0.priority == .userBlocking }.map { $0.wait.percentileNanos(0.99) }.max() ?? 0
    }

    /// The number of performance cores minus one (at least one), so CPU-bound background work always
    /// leaves a performance core to the main thread and the render threads.
    public static var defaultCPUWidth: Int {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if blockingSysctlByName("hw.perflevel0.logicalcpu", &cores, &size, nil, 0) != 0 || cores <= 0 {
            cores = Int32(clamping: sysconf(_SC_NPROCESSORS_ONLN))
        }
        return max(1, Int(cores) - 1)
    }

    /// Runs `body` on `lane` at `priority` (boosted to the caller's priority at the call) and returns its
    /// result. A later escalation of the caller does not boost it; a ``WorkHandle`` item can be raised later.
    ///
    /// - Parameters:
    ///   - priority: how much a person waits for it; the item runs at the higher of this and the caller's.
    ///   - lane: the kind of blocking work `body` does.
    ///   - shutdown: what ``shutdown()`` does with it; default ``ShutdownBehavior/skipOnShutdown``.
    ///   - fileID: the caller's `#fileID`, which names a slow block-shutdown item (leave the default).
    ///   - line: the caller's `#line`.
    ///   - body: the blocking work. It runs on a lane thread, never on the cooperative pool.
    /// - Returns: what `body` returns.
    /// - Throws: what `body` throws; `CancellationError` when the caller's task is cancelled before the
    ///   item starts (the item then never runs), or when shutdown dropped it. A started item runs to its end.
    public func run<T: Sendable>(_ priority: WorkPriority, mayBlock lane: BlockingLane,
                                 shutdown: ShutdownBehavior = .skipOnShutdown,
                                 fileID: StaticString = #fileID, line: UInt = #line,
                                 _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        noteAwaited(priority, site: CallSite(fileID: fileID, line: line))
        let id = nextID()
        let start = max(priority, WorkPriority(Task.currentPriority))
        // No withTaskPriorityEscalationHandler here: its runtime entry point
        // (swift_task_addPriorityEscalationHandler) is strong-linked, so any reference, even under
        // `#available(macOS 26.0, *)`, stops dyld before main on macOS 14 and 15. A later waiter's
        // escalation does not move a queued item up; the item runs at the caller's priority at submit.
        return try await enqueue(id, on: lane, at: start, shutdown: shutdown,
                                 site: CallSite(fileID: fileID, line: line), body)
    }

    /// Queues `body` on `lane` at `priority` (in the `cap` class, if any) and awaits it. The caller has
    /// checked cancellation and boosted `priority`.
    func enqueue<T: Sendable>(_ id: UInt64, on lane: BlockingLane, at priority: WorkPriority, cap: LaneCap? = nil,
                              shutdown: ShutdownBehavior, site: CallSite,
                              _ body: @escaping @Sendable () throws -> T) async throws -> T {
        let scheduler = lanes[lane.rawValue]
        return try await withTaskCancellationHandler {
            try await withOnceThrowingContinuation { (continuation: OnceContinuation<T, any Error>) in
                guard let job = makeJob(id: id, lane: lane, shutdown: shutdown, site: site,
                                        work: { continuation.resume(with: Result { try body() }) },
                                        abandoned: { continuation.resume(throwing: CancellationError()) }) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // Checked under the lane's lock, so a cancel either finds the item queued or stops it here.
                submitted(scheduler.submit(job, at: priority, posted: false, cap: cap, unless: { Task.isCancelled }), job, on: lane)
            }
        } onCancel: {
            scheduler.remove(id)?.abandon()
        }
    }

    /// Queues `body` on `lane` at `priority` and returns at once; nothing awaits it, so nothing boosts it.
    ///
    /// - Parameters:
    ///   - priority: how much a person waits for it.
    ///   - lane: the kind of blocking work `body` does.
    ///   - shutdown: what ``shutdown()`` does with it; one bounded save whose loss loses data is
    ///     ``ShutdownBehavior/blockShutdown``.
    ///   - fileID: the caller's `#fileID`, which names a slow block-shutdown item (leave the default).
    ///   - line: the caller's `#line`.
    ///   - abandoned: runs instead of `body` when shutdown drops the item before it started, or refuses it
    ///     (a block-shutdown item posted after ``shutdown()`` returned); on the dropping thread.
    ///   - body: the blocking work. It runs on a lane thread, never on the cooperative pool.
    public func post(_ priority: WorkPriority, mayBlock lane: BlockingLane,
                     shutdown: ShutdownBehavior = .skipOnShutdown,
                     fileID: StaticString = #fileID, line: UInt = #line,
                     abandoned: @escaping @Sendable () -> Void = {}, _ body: @escaping @Sendable () -> Void) {
        guard let job = makeJob(id: nextID(), lane: lane, shutdown: shutdown,
                                site: CallSite(fileID: fileID, line: line), work: body, abandoned: abandoned) else {
            return abandoned()
        }
        submitted(lanes[lane.rawValue].submit(job, at: priority, posted: true, unless: { false }), job, on: lane)
    }

    /// Holds posted ``WorkPriority/idle`` and ``WorkPriority/bestEffort`` items on every lane until the
    /// matching ``endBestEffortFence()``. Items that already run finish; higher priorities and awaited
    /// items are not held; held items keep their priority and QoS. Fences nest. Chrome:
    /// `ThreadPoolInstance::BeginBestEffortFence` (base/task/thread_pool/thread_pool_instance.h), raised
    /// for startup and lowered after it (cmux lowers it at the reveal).
    public func beginBestEffortFence() {
        for lane in lanes { lane.fence() }
    }

    /// Lowers one ``beginBestEffortFence()``; when none is left, the held items start in post order
    /// within each priority. A call with no fence up does nothing. ``shutdown()`` lifts every fence.
    public func endBestEffortFence() {
        for lane in lanes { lane.unfence() }
    }

    /// Starts nothing yet: names off-main work whose result goes back to the main thread with
    /// ``Pending/reply(on:class:owner:file:line:_:)``, which queues it. Chrome's
    /// `PostTaskAndReplyWithResult` (base/task/task_runner.h): the reply is a posted main task with
    /// a class, an owner and its posting site, so main-actor callers need no `await` (whose resume
    /// would be a main job nobody attributes). Like ``post(_:mayBlock:shutdown:fileID:line:_:)``, the item runs
    /// at `priority`, never boosted by the caller; when shutdown drops it, the reply never runs.
    ///
    /// - Parameters:
    ///   - priority: how much a person waits for it.
    ///   - lane: the kind of blocking work `body` does.
    ///   - shutdown: what ``shutdown()`` does with it.
    ///   - body: the off-main work; return a `Result` for work that can fail.
    /// - Returns: the work, queued by its ``Pending/reply(on:class:owner:file:line:_:)``.
    ///
    /// Disfavored: a non-throwing closure matches this `() -> T` exactly, so without it
    /// `try await work.run(.x, mayBlock: .y) { ... }` picked this overload, built a `Pending` and ran nothing.
    /// The async ``run(_:mayBlock:shutdown:fileID:line:_:)`` wins wherever both fit; this one is chosen where
    /// only it fits (a sync caller, or a call followed by `.reply`).
    @_disfavoredOverload
    public func run<T: Sendable>(_ priority: WorkPriority, mayBlock lane: BlockingLane, shutdown: ShutdownBehavior = .skipOnShutdown,
                                 _ body: @escaping @Sendable () -> T) -> Pending<T> {
        Pending(work: self, priority: priority, lane: lane, shutdown: shutdown, body: body)
    }

    /// Off-main work waiting for its reply (the non-async `run`); nothing runs until
    /// ``reply(on:class:owner:file:line:_:)`` queues it.
    public struct Pending<T: Sendable>: Sendable {
        let work: BackgroundWork
        let priority: WorkPriority
        let lane: BlockingLane
        let shutdown: ShutdownBehavior
        let body: @Sendable () -> T

        /// Queues the work; its result is posted to `mainWork` in `workClass` as `owner`, and the
        /// board records this call's file and line as the reply's posting site.
        public func reply(on mainWork: MainWorkScheduler, class workClass: BudgetedWorkClass, owner: MainTaskOwner,
                          file: StaticString = #fileID, line: UInt = #line, _ reply: @escaping @MainActor @Sendable (T) -> Void) {
            let site = MainPostSite(file: file, line: line), body = self.body
            work.post(priority, mayBlock: lane, shutdown: shutdown, fileID: file, line: line) {
                let value = body()
                mainWork.postFromAnyThread(workClass, owner: owner, site: site) { reply(value) }
            }
        }

        /// ``reply(on:class:owner:file:line:_:)`` with an owner name (interned on the board here).
        public func reply(on mainWork: MainWorkScheduler, class workClass: BudgetedWorkClass, owner: String,
                          file: StaticString = #fileID, line: UInt = #line, _ reply: @escaping @MainActor @Sendable (T) -> Void) {
            self.reply(on: mainWork, class: workClass, owner: mainWork.board.owner(owner), file: file, line: line, reply)
        }
    }

    /// Abandons a refused item and reports a queued one.
    func submitted(_ result: LaneScheduler.Submitted, _ job: LaneJob, on lane: BlockingLane) {
        switch result {
        case .refused: job.abandon()
        case .started: break
        case .queued(let priority): onQueued(lane, priority)
        }
    }

    /// Starts shutdown and returns at once: drops every lane item that has not started except
    /// ``ShutdownBehavior/blockShutdown`` ones, cancels every ``ShutdownBehavior/skipOnShutdown`` task, refuses
    /// new items other than block-shutdown ones (a refused ``task(_:shutdown:fileID:line:_:)`` throws
    /// `CancellationError`, and so does a continue-on-shutdown task that had not started), lifts the
    /// best-effort fence so held block-shutdown items run, and raises block-shutdown lane items to
    /// `.userInitiated` (queued ones start at it, running ones get one override each). A ``LaunchFence``'s cap
    /// timer is cancelled. Started continue-on-shutdown items run on. A second
    /// call does nothing more. Quit calls it before the engines stop, so the lanes drain alongside them
    /// (QuitCompletion).
    public func beginShutdown() {
        let (cancels, launchCaps) = state.withLock { state -> ([@Sendable () -> Void], [DemandTimer]) in
            state.closed = true
            defer { state.launchCaps = [:] }
            return (state.skipTaskCancels(), Array(state.launchCaps.values))
        }
        // The lanes lift every fence below, so no launch fence cap stays armed.
        for cap in launchCaps { cap.cancel() }
        for cancel in cancels { cancel() }
        for lane in lanes {
            for job in lane.close() { job.abandon() }
        }
    }

    /// ``beginShutdown()``, then returns when every block-shutdown item has finished; from then on a
    /// block-shutdown item is refused as well. Started continue-on-shutdown items are not awaited. Quit awaits
    /// it once, after the engines stop and inside its deadline (QuitCompletion).
    public func shutdown() async {
        beginShutdown()
        // A waiter the drain state drops unresumed ends abandoned: shutdown returns.
        try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
            let now = state.withLock { state -> Bool in
                if state.blocking == 0 {
                    state.drained = true
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if now { continuation.resume(returning: ()) }
        }
    }

    func nextID() -> UInt64 {
        state.withLock { $0.takeID() }
    }

    /// Items submitted from now on no longer call `onRan` (one relaxed load per item); items already queued still
    /// report. The startup trace calls it when it closes.
    public func stopReportingRuns() {
        reportsRuns.store(false, ordering: .relaxed)
    }

    /// The item's run report to `onRan` while runs are reported, at the level the lane ran it at, with the start and
    /// end stamps the lane took for its stats (no clock read of its own); nil otherwise.
    private func runReport(lane: BlockingLane) -> (@Sendable (WorkPriority, UInt64, UInt64) -> Void)? {
        guard let onRan, reportsRuns.load(ordering: .relaxed) else { return nil }
        return { priority, start, end in onRan(lane, priority, start, end) }
    }

    /// The lane job for an item; nil for a block-shutdown item that came after ``shutdown()`` returned
    /// (recorded, never run). `onRan` gets the level the lane ran it at, not the one it was posted at.
    /// `finished` runs once the item ran or was abandoned, after its shutdown count dropped (a ``WorkSequence``
    /// starts its next item then). The post is traced here, at `site`.
    func makeJob(id: UInt64, lane: BlockingLane, shutdown: ShutdownBehavior,
                 site: CallSite, work body: @escaping @Sendable () -> Void,
                 abandoned: @escaping @Sendable () -> Void,
                 finished: @escaping @Sendable () -> Void = {}) -> LaneJob? {
        let work: @Sendable (WorkPriority) -> Void = { _ in body() }
        let report = runReport(lane: lane)
        guard shutdown == .blockShutdown else {
            return LaneJob(id: id, shutdown: shutdown, trace: tracePost(site, on: lane), work: work, ran: report,
                           abandoned: abandoned, done: finished)
        }
        let taken = state.withLock { state -> Bool in
            guard !state.drained else { return false }
            state.blocking += 1
            return true
        }
        guard taken else {
            blockShutdownRefused(site)
            return nil
        }
        return LaneJob(id: id, shutdown: shutdown, trace: tracePost(site, on: lane), work: work,
                       ran: blockShutdownRan(site, then: report), abandoned: abandoned, done: { [self] in
            blockItemFinished()
            finished()
        })
    }

    /// One block-shutdown item (lane item or task) finished or was abandoned: resumes ``shutdown()`` when it
    /// was the last.
    func blockItemFinished() {
        let waiters = state.withLock { state -> [OnceContinuation<Void, OnceContinuationError>] in
            state.blocking -= 1
            guard state.blocking == 0, !state.waiters.isEmpty else { return [] }
            // A shutdown() waits: it returns now, so later block items are refused.
            state.drained = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: ()) }
    }

}
