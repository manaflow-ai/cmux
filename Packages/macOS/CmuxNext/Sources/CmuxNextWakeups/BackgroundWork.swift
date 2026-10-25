import CmuxNextCompat
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
/// One instance per app, built in the composition root (AppServices) and passed through `init`;
/// tests build their own.
///
/// ```swift
/// let data = try await work.run(.userVisible, mayBlock: .files) { try Data(contentsOf: url) }
/// work.post(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) { try? data.write(to: url, options: .atomic) }
/// let addresses = try await work.run(.userBlocking, mayBlock: .system) { resolve(host) }
/// let page = work.task(.userVisible) { try await fetch(url) }  // async work, no blocking call
/// ```
///
/// Shutdown, as Chrome's `TaskTracker` (`base/task/thread_pool/task_tracker.cc`): ``shutdown()`` drops or
/// cancels ``ShutdownBehavior/skipOnShutdown`` items, lets started ``ShutdownBehavior/continueOnShutdown``
/// ones run, refuses new items other than ``ShutdownBehavior/blockShutdown`` ones, and returns when every
/// block-shutdown item, lane item or ``task(_:shutdown:fileID:line:_:)``, has finished.
public final class BackgroundWork: Sendable {
    /// How many ``BlockingLane/cpu`` items run at once.
    public let cpuWidth: Int
    /// The label prefix of every lane slot's dispatch queue (`<label>.<lane>.<priority or slot>`).
    public let label: String
    private let lanes: [LaneScheduler]
    private let onQueued: @Sendable (BlockingLane, WorkPriority) -> Void
    /// The clock a block-shutdown item's run time is measured with (``blockShutdownLimit``).
    let uptimeNanos: @Sendable () -> UInt64
    // concurrency-allow: id counter, the shutdown count and the registered tasks, read and written synchronously by submitters, lane threads and finishing tasks (lock carve-out: counters and a dictionary, no I/O under it).
    let state = Mutex(DrainState())

    struct DrainState {
        var nextID: UInt64 = 1
        /// Block-shutdown items (lane items and tasks) that have not finished.
        var blocking = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        /// ``shutdown()`` has started: only block-shutdown items are taken.
        var closed = false
        /// The ``task(_:shutdown:fileID:line:_:)`` tasks that have not finished, by id.
        var tasks: [UInt64: RegisteredTask] = [:]
        /// Block-shutdown items that ran longer than ``blockShutdownLimit``, oldest first, at most
        /// ``overrunLimit``.
        var overruns: [BlockShutdownOverrun] = []

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
    ///   - uptimeNanos: the clock a block-shutdown item's run time is measured with, in nanoseconds; nil is
    ///     `CLOCK_UPTIME_RAW`. Tests pass their own.
    public init(cpuWidth: Int = BackgroundWork.defaultCPUWidth, label: String = "com.cmuxterm.next.work",
                onQueued: @escaping @Sendable (BlockingLane, WorkPriority) -> Void = { _, _ in },
                uptimeNanos: (@Sendable () -> UInt64)? = nil) {
        self.cpuWidth = max(1, cpuWidth)
        self.label = label
        self.onQueued = onQueued
        self.uptimeNanos = uptimeNanos ?? { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
        lanes = BlockingLane.allCases.map { lane in
            switch lane {
            case .files: LaneScheduler(label: "\(label).\(lane)", policy: .perPriority)
            case .system: LaneScheduler(label: "\(label).\(lane)", policy: .shared(width: Self.systemWidth))
            case .cpu: LaneScheduler(label: "\(label).\(lane)", policy: .shared(width: max(1, cpuWidth)))
            }
        }
    }

    /// How many ``BlockingLane/system`` items run at once: Chrome's limit for concurrent system DNS
    /// lookups (`kDefaultMaxSystemTasks`, net/dns/host_resolver_manager.cc). A system call can hang for
    /// its own timeout (`getaddrinfo` up to 30 s); one hung call must not hold every later one.
    public static let systemWidth = 6

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

    private func enqueue<T: Sendable>(_ id: UInt64, on lane: BlockingLane, at priority: WorkPriority,
                                      shutdown: ShutdownBehavior, site: CallSite,
                                      _ body: @escaping @Sendable () throws -> T) async throws -> T {
        let scheduler = lanes[lane.rawValue]
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                let job = makeJob(id: id, shutdown: shutdown, site: site,
                                  work: { continuation.resume(with: Result { try body() }) },
                                  abandoned: { continuation.resume(throwing: CancellationError()) })
                // Checked under the lane's lock, so a cancel either finds the item queued or stops it here.
                submitted(scheduler.submit(job, at: priority, unless: { Task.isCancelled }), job, on: lane)
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
        let job = makeJob(id: nextID(), shutdown: shutdown, site: CallSite(fileID: fileID, line: line),
                          work: body, abandoned: {})
        submitted(lanes[lane.rawValue].submit(job, at: priority, unless: { false }), job, on: lane)
    }

    /// Abandons a refused item and reports a queued one.
    private func submitted(_ result: LaneScheduler.Submitted, _ job: LaneJob, on lane: BlockingLane) {
        switch result {
        case .refused: job.abandon()
        case .started: break
        case .queued(let priority): onQueued(lane, priority)
        }
    }

    /// Starts shutdown: drops every lane item that has not started except ``ShutdownBehavior/blockShutdown``
    /// ones, cancels every ``ShutdownBehavior/skipOnShutdown`` task, refuses new items other than
    /// block-shutdown ones (a refused ``task(_:shutdown:fileID:line:_:)`` throws `CancellationError`), and
    /// returns when every block-shutdown item has finished. Started continue-on-shutdown items run on and
    /// are not awaited. Quit awaits it once, after its own saves and inside its deadline (QuitCoordinator).
    public func shutdown() async {
        let cancels = state.withLock { state in
            state.closed = true
            return state.skipTaskCancels()
        }
        for cancel in cancels { cancel() }
        for lane in lanes {
            for job in lane.close() { job.abandon() }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                if state.blocking == 0 { return true }
                state.waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    private func nextID() -> UInt64 {
        state.withLock { $0.takeID() }
    }

    private func makeJob(id: UInt64, shutdown: ShutdownBehavior, site: CallSite, work: @escaping @Sendable () -> Void,
                         abandoned: @escaping @Sendable () -> Void) -> LaneJob {
        guard shutdown == .blockShutdown else {
            return LaneJob(id: id, shutdown: shutdown, work: work, abandoned: abandoned, done: {})
        }
        state.withLock { $0.blocking += 1 }
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
            guard state.blocking == 0 else { return [] }
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

}
