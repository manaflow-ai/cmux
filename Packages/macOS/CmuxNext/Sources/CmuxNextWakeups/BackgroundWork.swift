import CmuxNextCompat
public import CmuxNextTrace
import Darwin
import Dispatch

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
/// No later escalation, on any macOS: when a low task awaits an item and a higher task later awaits
/// that low task, the item stays at its priority, possibly behind other low work. Swift's escalation
/// hook (`withTaskPriorityEscalationHandler`) exists only on macOS 26 and its runtime entry point is
/// strong-linked, so even a reference under `#available` stops launch on macOS 14 and 15. That is a
/// latency inversion, never a main-thread wait (nothing here waits synchronously). So start work that
/// a person may wait for at that priority; do not start it low and count on a later waiter to raise it.
/// To keep work low, post it, or await it from a task that is itself low
/// (`Task(priority: WorkPriority.bestEffort.taskPriority)`).
///
/// Startup fence: between ``beginBestEffortFence()`` and ``endBestEffortFence()`` posted
/// ``WorkPriority/idle`` and ``WorkPriority/bestEffort`` items wait, so they do not compete with launch.
/// An awaited item is never held: someone waits for it, so it runs at once at its own priority.
///
/// One instance per app, built in the composition root (AppServices) and passed through `init`;
/// tests build their own.
///
/// ```swift
/// let data = try await work.run(.userVisible, mayBlock: .files) { try Data(contentsOf: url) }
/// work.post(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) { try? data.write(to: url, options: .atomic) }
/// let addresses = try await work.run(.userBlocking, mayBlock: .system) { resolve(host) }
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
public final class BackgroundWork: Sendable {
    /// How many ``BlockingLane/cpu`` items run at once.
    public let cpuWidth: Int
    /// The label prefix of every lane slot's dispatch queue (`<label>.<lane>.<priority or slot>`).
    public let label: String
    private let lanes: [LaneScheduler]
    private let onQueued: @Sendable (BlockingLane, WorkPriority) -> Void
    private let onRan: (@Sendable (BlockingLane, WorkPriority, UInt64, UInt64) -> Void)?
    /// False after ``stopReportingRuns()``: items submitted later skip `onRan` and the clock.
    private let reportsRuns = Atomic<Bool>(true)
    /// The clock a block-shutdown item's run time is measured with (``blockShutdownLimit``).
    let uptimeNanos: @Sendable () -> UInt64
    // concurrency-allow: id counter, the shutdown count and the registered tasks, read and written synchronously by submitters, lane threads and finishing tasks (lock carve-out: counters and a dictionary, no I/O under it).
    let state = Mutex(DrainState())
    /// Test seams around a ``task(_:shutdown:fileID:line:_:)`` start; production uses ``TaskHooks/none``.
    let taskHooks: TaskHooks

    struct DrainState {
        var nextID: UInt64 = 1
        /// Block-shutdown items (lane items and tasks) that have not finished.
        var blocking = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
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

        mutating func takeID() -> UInt64 {
            defer { nextID += 1 }
            return nextID
        }
    }

    /// Creates the lanes.
    ///
    /// - Parameters:
    ///   - cpuWidth: how many ``BlockingLane/cpu`` items run at once; default ``defaultCPUWidth``.
    ///   - label: the dispatch queue label prefix, which shows in traces and crash reports.
    ///   - onQueued: called with the lane and the priority each time an item has to wait for a slot (it
    ///     did not start at once), after it is queued and before it can start; default nothing. Traces
    ///     count waits with it; tests use it as the point after which a cancel or an escalation meets a
    ///     queued item, not the checks at the call.
    ///   - hangs: watches each item's run on its lane thread for a hang, with the lane's
    ///     ``hangDeadline(_:)``; the wait for a slot is not watched. nil (the default) watches nothing.
    ///   - onRan: called on the lane thread after each item ran, with its lane, its priority and its start
    ///     and end in `uptimeNanos` nanoseconds; default none, and then no item reads the clock for it. The
    ///     startup trace (CmuxNextLaunch's StartupTrace) records lane jobs with it until it closes
    ///     (``stopReportingRuns()``).
    ///   - uptimeNanos: the clock a block-shutdown item's run time is measured with, in nanoseconds; nil is
    ///     `CLOCK_UPTIME_RAW`. Tests pass their own.
    public convenience init(cpuWidth: Int = BackgroundWork.defaultCPUWidth, label: String = "com.cmuxterm.next.work",
                            hangs: (any HangWatchScoping)? = nil,
                            onQueued: @escaping @Sendable (BlockingLane, WorkPriority) -> Void = { _, _ in },
                            onRan: (@Sendable (BlockingLane, WorkPriority, UInt64, UInt64) -> Void)? = nil,
                            uptimeNanos: (@Sendable () -> UInt64)? = nil) {
        self.init(cpuWidth: cpuWidth, label: label, hangs: hangs, onQueued: onQueued, onRan: onRan,
                  uptimeNanos: uptimeNanos, taskHooks: .none)
    }

    /// The designated init; tests pass ``TaskHooks`` to stop a task between its steps.
    init(cpuWidth: Int, label: String, hangs: (any HangWatchScoping)? = nil,
         onQueued: @escaping @Sendable (BlockingLane, WorkPriority) -> Void,
         onRan: (@Sendable (BlockingLane, WorkPriority, UInt64, UInt64) -> Void)? = nil,
         uptimeNanos: (@Sendable () -> UInt64)?, taskHooks: TaskHooks) {
        self.taskHooks = taskHooks
        self.cpuWidth = max(1, cpuWidth)
        self.label = label
        self.onQueued = onQueued
        self.onRan = onRan
        self.uptimeNanos = uptimeNanos ?? { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
        lanes = BlockingLane.allCases.map { lane in
            let traits: (policy: LaneScheduler.Policy, mayBlock: Bool, caps: [LaneCap: Int]) = switch lane {
            case .files: (.perPriority, true, [:])
            case .system: (.shared(width: Self.systemWidth, reserved: Self.systemReserved), true, [.hostResolution: Self.hostResolutionCap])
            // The .cpu lane is sized to the cores: a blocking seam in one of its items is a wrong-lane violation.
            case .cpu: (.shared(width: max(1, cpuWidth)), false, [:])
            }
            let watched = hangs.map { HangWatchedLane(Self.hangScopeName(lane), deadline: Self.hangDeadline(lane), on: $0) }
            return LaneScheduler(label: "\(label).\(lane)", policy: traits.policy, mayBlock: traits.mayBlock, caps: traits.caps,
                                 hangWatched: watched)
        }
    }

    /// How long one item of `lane` may run before the hang watcher reports it: a file operation 5 s,
    /// a system call 30 s (`getaddrinfo`'s own timeout, see ``systemWidth``), CPU work 10 s.
    public static func hangDeadline(_ lane: BlockingLane) -> Duration {
        switch lane {
        case .files: .seconds(5)
        case .system: .seconds(30)
        case .cpu: .seconds(10)
        }
    }

    /// The name a hang report gives an item of `lane`.
    static func hangScopeName(_ lane: BlockingLane) -> StaticString {
        switch lane {
        case .files: "lane.files"
        case .system: "lane.system"
        case .cpu: "lane.cpu"
        }
    }

    /// The number of performance cores minus one (at least one), so CPU-bound background work always
    /// leaves a performance core to the main thread and the render threads.
    public static var defaultCPUWidth: Int {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &cores, &size, nil, 0) != 0 || cores <= 0 {
            cores = Int32(clamping: sysconf(_SC_NPROCESSORS_ONLN))
        }
        return max(1, Int(cores) - 1)
    }

    /// Runs `body` on `lane` at `priority` (boosted to the caller's priority at the call) and returns its
    /// result. A later escalation of the caller does not boost it (see the type's note).
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
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                guard let job = makeJob(id: id, lane: lane, priority: priority, shutdown: shutdown, site: site,
                                        work: { continuation.resume(with: Result { try body() }) },
                                        abandoned: { continuation.resume(throwing: CancellationError()) }) else {
                    return continuation.resume(throwing: CancellationError())
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
    ///   - body: the blocking work. It runs on a lane thread, never on the cooperative pool.
    public func post(_ priority: WorkPriority, mayBlock lane: BlockingLane,
                     shutdown: ShutdownBehavior = .skipOnShutdown,
                     fileID: StaticString = #fileID, line: UInt = #line, _ body: @escaping @Sendable () -> Void) {
        guard let job = makeJob(id: nextID(), lane: lane, priority: priority, shutdown: shutdown,
                                site: CallSite(fileID: fileID, line: line), work: body, abandoned: {}) else { return }
        submitted(lanes[lane.rawValue].submit(job, at: priority, posted: true, unless: { false }), job, on: lane)
    }

    /// Holds posted ``WorkPriority/idle`` and ``WorkPriority/bestEffort`` items on every lane until the
    /// matching ``endBestEffortFence()``. Items that already run finish; higher priorities and awaited
    /// items are not held; held items keep their priority and QoS. Fences nest. Chrome:
    /// `ThreadPoolInstance::BeginBestEffortFence` (base/task/thread_pool/thread_pool_instance.h), raised
    /// for startup and lowered at startup complete.
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
    private func submitted(_ result: LaneScheduler.Submitted, _ job: LaneJob, on lane: BlockingLane) {
        switch result {
        case .refused: job.abandon()
        case .started: break
        case .queued(let priority): onQueued(lane, priority)
        }
    }

    /// Starts shutdown and returns at once: drops every lane item that has not started except
    /// ``ShutdownBehavior/blockShutdown`` ones, cancels every ``ShutdownBehavior/skipOnShutdown`` task, refuses
    /// new items other than block-shutdown ones (a refused ``task(_:shutdown:fileID:line:_:)`` throws
    /// `CancellationError`, and so does a continue-on-shutdown task that had not started), and lifts the
    /// best-effort fence so held block-shutdown items run. Started continue-on-shutdown items run on. A second
    /// call does nothing more. Quit calls it before the engines stop, so the lanes drain alongside them
    /// (QuitCompletion).
    public func beginShutdown() {
        let cancels = state.withLock { state in
            state.closed = true
            return state.skipTaskCancels()
        }
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
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                if state.blocking == 0 {
                    state.drained = true
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func nextID() -> UInt64 {
        state.withLock { $0.takeID() }
    }

    /// The lane job for an item; nil for a block-shutdown item that came after ``shutdown()`` returned
    /// (recorded, never run).
    /// Items submitted from now on no longer call `onRan` or read the clock for it (one relaxed load per
    /// item); items already queued still report. The startup trace calls it when it closes.
    public func stopReportingRuns() {
        reportsRuns.store(false, ordering: .relaxed)
    }

    /// The item's work, wrapped to report its run to `onRan` while runs are reported.
    private func reporting(_ work: @escaping @Sendable () -> Void, lane: BlockingLane,
                           priority: WorkPriority) -> @Sendable () -> Void {
        guard let onRan, reportsRuns.load(ordering: .relaxed) else { return work }
        let uptimeNanos = uptimeNanos
        return {
            let start = uptimeNanos()
            work()
            onRan(lane, priority, start, uptimeNanos())
        }
    }

    private func makeJob(id: UInt64, lane: BlockingLane, priority: WorkPriority, shutdown: ShutdownBehavior,
                         site: CallSite, work unreported: @escaping @Sendable () -> Void,
                         abandoned: @escaping @Sendable () -> Void) -> LaneJob? {
        let work = reporting(unreported, lane: lane, priority: priority)
        guard shutdown == .blockShutdown else {
            return LaneJob(id: id, shutdown: shutdown, work: work, abandoned: abandoned, done: {})
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
        return LaneJob(id: id, shutdown: shutdown, work: { [self] in
            let start = blockShutdownStarted()
            work()
            blockShutdownEnded(site, since: start)
        }, abandoned: abandoned, done: { [self] in blockItemFinished() })
    }

    /// One block-shutdown item (lane item or task) finished or was abandoned: resumes ``shutdown()`` when it
    /// was the last.
    func blockItemFinished() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.blocking -= 1
            guard state.blocking == 0, !state.waiters.isEmpty else { return [] }
            // A shutdown() waits: it returns now, so later block items are refused.
            state.drained = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

}
