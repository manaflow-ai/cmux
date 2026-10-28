import CmuxNextCompat
import CmuxNextSignposts
import CmuxNextTrace
import Darwin
import Dispatch

/// The queue of one ``BlockingLane``: which item runs next, on which slot, at which QoS.
///
/// A slot is a serial `DispatchQueue` that runs one item at a time at the item's QoS (`.enforceQoS`);
/// GCD makes a thread only while a slot has work. Each item of a lane that may block (files, system) runs with
/// its thread marked ``CmuxNextCompat/BlockingContext/lane``, so the blocking detector allows its seams except a
/// wait for other work (``CmuxNextCompat/BlockingKind/isSyncPrimitive``), which records a
/// ``CmuxNextCompat/BlockingContext/laneSync`` site; an item of the cpu lane runs marked
/// ``CmuxNextCompat/BlockingContext/cpuLane``, where a seam records a ``CmuxNextCompat/BlockingKind/wrongLane`` site
/// (Debug and bench-checks builds). A `perPriority` lane (files) has its own
/// slots for each ``WorkPriority`` (``FilesLaneWidths``), so a best-effort write never sits in front of a
/// user-blocking read and one slow read does not hold the next one; each level starts its items in post order.
/// Nothing here orders items that run at once: a ``WorkSequence`` does (Chrome's `SequencedTaskRunner`). A
/// `shared` lane (system, cpu) has `width` slots for every priority and starts the highest-priority pending
/// item first. `reserved` of them run only ``WorkPriority/userBlocking`` items of no
/// ``LaneCap`` class: any other item starts only while fewer than `width - reserved` slots are busy, whatever
/// the busy slots run, so neither hung lower work nor hung capped work (a resolver at user-blocking) holds the
/// last slot a person waits for. Chrome's `PrioritizedDispatcher` (net/base/prioritized_dispatcher.cc), which
/// counts every running job against `max_running_jobs_[priority]` (`Limits::reserved_slots`). An item of a
/// ``LaneCap`` class also runs only while fewer than the class's cap run, so one hung kind leaves the lane's
/// other slots to the rest.
///
/// A `shared` lane runs at most ``bestEffortCap`` ``WorkPriority/bestEffort`` and ``WorkPriority/idle`` items at
/// once, at most ``idleCap`` of them idle, however many slots are free, so a burst of low work never fills the
/// lane in front of later user-visible work: Chrome's `kMaxBestEffortTasks` (base/task/thread_pool/thread_pool_impl.cc,
/// enforced by `ThreadGroup::max_best_effort_tasks_`). The idle limit is cmux's, as Chrome has no level below
/// best effort. An item boosted by its waiter runs at the waiter's level and is not capped. A `perPriority`
/// lane is held to its widths instead (``FilesLaneWidths``: 2 best-effort and 1 idle slot), so a hung low read
/// never holds the other low level. On a lane with ``MayBlockCompensation`` (system), a low item
/// that has run longer than its threshold stops counting against both limits, so hung calls never hold every later
/// low item: Chrome's `ThreadGroup::BlockingStarted`, which raises `max_best_effort_tasks_` for a best-effort task
/// blocked past the may-block threshold (base/task/thread_pool/thread_group.cc). The lane rechecks only while a
/// low item waits for the cap, on one one-shot ``DemandTimer`` set to the next item's threshold. After ``close()``
/// neither limit holds, so block-shutdown items quit waits for are never capped (Chrome's
/// `ThreadGroup::OnShutdownStarted` sets `max_best_effort_tasks_` to `max_tasks_`).
///
/// While a best-effort fence is up (``fence()``), a posted ``WorkPriority/idle`` or
/// ``WorkPriority/bestEffort`` item stays queued in post order; an item someone awaits still runs at its
/// own QoS. Chrome's `CanRunPolicy::kForegroundOnly` (base/task/thread_pool/thread_pool_impl.cc).
/// Raising the fence only counts: an item that already runs is not waited on.
///
/// With a hang-watched lane, each slot registers on its own and each item's run on its slot is one hang scope
/// of that slot (Chrome's `WatchHangsInScope` in `TaskTracker::RunTask`, base/task/thread_pool/task_tracker.cc,
/// on each worker thread's own `HangWatchState`); the wait for a slot is not. Scopes nest only on one thread, so
/// items that run at once never share a registration.
///
/// While the trace's `task` category records, each item posted then runs inside one `task.run` slice
/// (``CmuxNextSignposts/SignpostName/taskRun``) on its slot thread, with its lane, priority and queue wait
/// (plans/cmux-next/trace.md "Blocking calls and lane jobs"): Chrome's `ThreadPool_RunTask` event in
/// `TaskTracker::RunTask` (base/task/thread_pool/task_tracker.cc), which carries the task's priority and queueing
/// time. The wait counts from the item's post: a plain lane item's is its submit here, a ``WorkSequence`` item's is
/// its post to the sequence (``postStamp()``), so it includes the wait behind the items in front of it, as Chrome
/// stamps a sequenced task's queue time when it is posted (base/task/thread_pool/sequence.cc). Off, an item pays one
/// relaxed load, at its post.
///
/// ``raise(_:to:awaited:)`` moves a queued item up to a higher list, and gives a running one a QoS override
/// on its slot thread until it ends (Chrome's `UpdateableSequencedTaskRunner::UpdatePriority` and
/// `ScopedBoostablePriority`).
///
/// Shutdown raises block-shutdown work, as Chrome runs BLOCK_SHUTDOWN tasks "with a normal thread priority" once
/// shutdown has started (`TaskTracker::StartShutdown` and the run policy it recomputes,
/// base/task/thread_pool/task_tracker.cc and thread_group.cc). Chrome raises the thread, never the order of a
/// sequence (`WorkerThread::GetDesiredThreadType`, worker_thread.cc), so after ``close()`` a
/// ``ShutdownBehavior/blockShutdown`` item starts at `.userInitiated` from its own level, and ``close()`` raises
/// each such item that already runs below it as ``raise(_:to:awaited:)`` does, with one ``ThreadQoSOverride`` on
/// its thread that the item's end lifts. A `perPriority` lane keeps each block item on its level's slots, so the
/// level keeps its width and post order and the levels still run side by side. A `shared` lane has no per-level
/// order: there ``close()`` moves the queued block items to the user-blocking list (and one submitted later is
/// queued there), so they may take the reserve too.
///
/// A yieldable job (``BackgroundWork/job(_:shutdown:state:fileID:line:_:)``) runs as one item per run. While every
/// slot of a `shared` lane is busy and an item above ``WorkPriority/bestEffort`` waits, the lane asks one running job
/// below it to yield (its ``JobDelegate/shouldYield``); the job stops between two chunks and its rest is queued again
/// in its old place (by id), so the waiting item takes the freed slot. Chrome's `ThreadGroup::ShouldYield`
/// (base/task/thread_pool/thread_group.cc): a job yields only to higher work, never to best-effort work, and one job
/// yields per waiting item (Chrome resets `max_allowed_sort_key_` when a worker decides to yield). After ``close()``
/// only a ``ShutdownBehavior/blockShutdown`` job's rest is queued, as only block-shutdown items are taken; the rest of
/// any other job is dropped (queued) or refused (yielded later), so its caller gets `CancellationError` whenever the
/// job yields. ``close()`` asks running ``ShutdownBehavior/skipOnShutdown`` jobs to yield; a running
/// continue-on-shutdown run is not asked by shutdown and may end the job in that run.
///
/// Every item's queue wait (submit to start on its slot thread) and run time count in the lane's ``LaneStats`` at
/// the level it ran, in every build: three reads of the lane's clock (submit, start, end) and four relaxed atomic
/// adds per item, no lock (Chrome's `TaskTracker::RecordLatencyHistogram` counts post to start the same way). The
/// item's own run report (``BackgroundWork``'s `onRan`, the block-shutdown check) gets the same start and end.
final class LaneScheduler: Sendable {
    /// How the lane's slots register with the hang watch: each slot under `name`, each item with `deadline`.
    struct HangWatching: Sendable {
        let name: StaticString
        let deadline: Duration
        let watch: any HangWatchScoping
    }

    /// How many ``WorkPriority/bestEffort`` and ``WorkPriority/idle`` items a `shared` lane runs at once
    /// (Chrome's `kMaxBestEffortTasks`).
    static let bestEffortCap = 2
    /// How many of the ``bestEffortCap`` items may be ``WorkPriority/idle``.
    static let idleCap = 1

    /// How a lane whose items may block stops counting a low item that blocks (Chrome's may-block threshold).
    struct MayBlockCompensation: Sendable {
        /// How long a low item runs before it stops counting against the caps.
        let threshold: Duration
        /// The time since the lane was made, on the lane's clock.
        let elapsed: @Sendable () -> Duration
        /// The clock the recheck timer sleeps on.
        let clock: any Clock<Duration>

        init(threshold: Duration, clock: any Clock<Duration>) {
            self.threshold = threshold
            self.clock = clock
            elapsed = clock.stopwatch()
        }
    }

    enum Policy: Sendable {
        /// `widths[level.rawValue]` slots for each ``WorkPriority``, run only by items of that level.
        case perPriority(widths: [Int])
        /// `width` slots for every priority, `reserved` of them (at most `width - 1`) for user-blocking items of no
        /// capped class only.
        case shared(width: Int, reserved: Int = 0)
    }

    private struct Entry {
        var job: LaneJob
        /// Nobody awaits it, so a best-effort fence holds it when its level is at most best effort.
        var posted: Bool
        /// The capped class it belongs to, if any.
        var cap: LaneCap?
        /// A ``WorkHandle`` item, which ``raise(_:to:awaited:)`` may boost while it runs.
        var raisable: Bool
        /// When it was submitted, on the lane's stats clock.
        var queuedAt: UInt64
        /// A run of a yieldable job: the lane asks it to yield through this delegate while it runs.
        var delegate: JobDelegate?
        /// The trace clock at its post while the `task` category recorded; nil records no slice.
        var tracedPost: UInt64?
    }

    /// What one busy slot runs: its item, level, capped class and start (on the lane's ``MayBlockCompensation``
    /// clock), and the overrides a raise or shutdown started on it.
    private struct Running {
        var id: UInt64
        var priority: WorkPriority
        var cap: LaneCap?
        var started: Duration
        /// Whether a raise or shutdown may boost it; only such an item records its thread.
        var raisable: Bool
        /// A ``ShutdownBehavior/blockShutdown`` item, which ``close()`` raises to ``WorkPriority/userBlocking``.
        var blockShutdown: Bool
        /// The slot thread's Mach port once a raisable item runs on it; 0 before.
        var thread: mach_port_t = 0
        /// The level a raise asked for above `priority`; nil when none did.
        var raised: WorkPriority?
        /// The overrides started on `thread`, ended when the item finishes.
        var overrides: [ThreadQoSOverride.Token] = []
        /// A run of a yieldable job: how the lane asks it to yield.
        var delegate: JobDelegate?
        /// The lane asked this job run to yield; its slot counts as freeing for the items that wait.
        var yieldAsked = false
        /// A ``ShutdownBehavior/skipOnShutdown`` item, which ``close()`` asks to yield when it is a job run.
        var skipsOnShutdown = false
    }

    private struct State {
        var pending: [[Entry]] = Array(repeating: [], count: WorkPriority.allCases.count)
        /// Per slot: what it runs, nil while it is free.
        var running: [Running?]
        /// Slots only a ``WorkPriority/userBlocking`` item of no capped class may take.
        let reserved: Int
        /// How many items of each capped class may run at once.
        let caps: [LaneCap: Int]
        var closed = false
        var fences = 0
        /// How long a low item runs before it stops counting against the caps; nil counts it for its whole run.
        let mayBlockThreshold: Duration?
        /// The lane's clock at the current pump.
        var now: Duration = .zero
        /// When the recheck timer fires, while it is set.
        var recheckAt: Duration?

        /// Shutdown lifts the fence so block-shutdown items finish (Chrome: `ThreadPoolImpl::Shutdown`
        /// sets `CanRunPolicy::kAll` once shutdown has started).
        var fenced: Bool { fences > 0 && !closed }

        /// The capped classes that run as many items as their cap allows.
        var fullCaps: Set<LaneCap> {
            guard !caps.isEmpty else { return [] }
            var counts: [LaneCap: Int] = [:]
            for case let cap? in running.map({ $0?.cap }) { counts[cap, default: 0] += 1 }
            return Set(caps.compactMap { cap, limit in counts[cap, default: 0] >= limit ? cap : nil })
        }

        /// Whether a slot outside the reserve is free. Every busy slot counts, whatever it runs: Chrome's
        /// `PrioritizedDispatcher::Limits` compare all running jobs with the limit of the job's priority.
        var unreservedFree: Bool {
            running.lazy.compactMap { $0 }.count < running.count - reserved
        }

        /// The running low items that count against the caps: every one, or on a may-block lane those not yet
        /// past the threshold.
        var countedLow: [Running] {
            running.compactMap { busy in
                guard let busy, busy.priority <= .bestEffort else { return nil }
                if let mayBlockThreshold, now - busy.started >= mayBlockThreshold { return nil }
                return busy
            }
        }

        /// Whether one more item at `level` stays inside ``LaneScheduler/bestEffortCap`` and
        /// ``LaneScheduler/idleCap``; a level above best effort, and any level after ``LaneScheduler/close()``, always does.
        func underBestEffortCap(_ level: WorkPriority) -> Bool {
            guard level <= .bestEffort, !closed else { return true }
            let low = countedLow
            let idle = low.filter { $0.priority == .idle }.count
            return low.count < LaneScheduler.bestEffortCap && (level > .idle || idle < LaneScheduler.idleCap)
        }

        /// When a counted low item passes the may-block threshold while a low item waits only for the caps; nil
        /// when nothing waits for them or the lane counts every item for its whole run.
        func nextRecount() -> Duration? {
            guard let mayBlockThreshold, unreservedFree else { return nil }
            let full = fullCaps
            let held = [WorkPriority.bestEffort, .idle].contains { level in
                !underBestEffortCap(level) && next(at: level, full: full) != nil
            }
            guard held else { return nil }
            return countedLow.map { $0.started + mayBlockThreshold }.min()
        }

        /// The index of the first item at `level` that may start now, skipping the `full` capped classes, and
        /// every capped item when `uncappedOnly`.
        func next(at level: WorkPriority, full: Set<LaneCap>, uncappedOnly: Bool = false) -> Int? {
            let holdsPosted = fenced && level <= .bestEffort
            return pending[level.rawValue].firstIndex { entry in
                guard !(holdsPosted && entry.posted) else { return false }
                guard let cap = entry.cap else { return true }
                return !uncappedOnly && !full.contains(cap)
            }
        }

        /// The highest level with an item that may start now, and that item's index. With only the reserve
        /// free, that is a user-blocking item of no capped class; a level at the best-effort cap is skipped.
        func highest() -> (level: WorkPriority, index: Int)? {
            let full = fullCaps
            let open = unreservedFree
            for level in WorkPriority.allCases.reversed() {
                if level < .userBlocking && !open { return nil }
                guard underBestEffortCap(level) else { continue }
                if let index = next(at: level, full: full, uncappedOnly: !open) { return (level, index) }
            }
            return nil
        }

        /// The busy slot of the job run that yields first to an item at `level`: one not asked yet, below `level`,
        /// the lowest level first; nil when none runs.
        func yieldCandidate(below level: WorkPriority) -> Int? {
            var best: (slot: Int, priority: WorkPriority)?
            for (slot, busy) in running.enumerated() {
                guard let busy, busy.delegate != nil, !busy.yieldAsked, busy.priority < level else { continue }
                if best.map({ busy.priority < $0.priority }) ?? true { best = (slot, busy.priority) }
            }
            return best?.slot
        }

        /// The level and index of pending item `id`.
        func locate(_ id: UInt64) -> (level: WorkPriority, index: Int)? {
            for level in WorkPriority.allCases {
                if let index = pending[level.rawValue].firstIndex(where: { $0.job.id == id }) { return (level, index) }
            }
            return nil
        }
    }

    private struct Start {
        var job: LaneJob
        var slot: Int
        var priority: WorkPriority
        var raisable: Bool
        /// Shutdown had started when the item was claimed.
        var closed: Bool
        /// When it was submitted, on the lane's stats clock.
        var queuedAt: UInt64
        /// The trace clock at its post, when its run records a `task.run` slice.
        var tracedPost: UInt64?

        /// A block-shutdown item claimed after shutdown started runs at user-blocking's QoS, from any level.
        var qos: DispatchQoS {
            (closed && job.shutdown == .blockShutdown ? WorkPriority.userBlocking : priority).qos
        }
    }

    /// Test seams on a slot's thread; ``none`` does nothing.
    struct Hooks: Sendable {
        /// Called on the slot's thread before a claimed item begins, so a test can start shutdown in between.
        var beforeBegin: @Sendable (_ slot: Int) -> Void

        static let none = Hooks(beforeBegin: { _ in })
    }

    /// The lane whose items this queue runs, in its trace slices; nil for a test's lane.
    private let lane: BlockingLane?
    /// The trace runtime its `task.run` slices go to.
    private let trace: TraceRuntime

    let policy: Policy
    /// Whether the lane's items may block (Chrome's `MayBlock()` trait): files and system may, cpu may not.
    private let mayBlock: Bool
    /// Each slot's hang-watch registration, by slot; each item runs in one scope of its slot's. Empty watches nothing.
    private let hangWatched: [HangWatchedLane]
    private let slots: [DispatchQueue]
    /// The lane's clock for the may-block threshold; nil counts a low item for its whole run.
    private let compensation: MayBlockCompensation?
    /// Rechecks the caps when a held low item may start because a running one passed the threshold.
    private let recheck: DemandTimer?
    /// Starts and ends the QoS override a raise or shutdown puts on a running item's slot thread.
    private let qosOverride: ThreadQoSOverride
    private let hooks: Hooks
    /// For a `perPriority` lane, the slots of each level (by `rawValue`); empty for a `shared` lane.
    private let levelSlots: [Range<Int>]
    /// Each item's queue wait and run time, per priority.
    let stats: LaneStats
    /// The clock of ``stats`` (`CLOCK_UPTIME_RAW` nanoseconds); tests pass their own.
    private let clock: @Sendable () -> UInt64
    // concurrency-allow: a short non-blocking critical section over the pending lists, taken from lane threads, cancel handlers and submitters that must not await (lock carve-out).
    private let state: Mutex<State>

    /// - Parameters:
    ///   - caps: how many items of each ``LaneCap`` class run at once; a class without an entry is not capped.
    ///   - compensation: on a `shared` lane whose items may block, when a low item stops counting against the
    ///     best-effort caps; nil counts it for its whole run.
    ///   - hangWatching: how each slot registers with the hang watch; nil watches nothing.
    ///   - qosOverride: the override a raise or shutdown of a running item starts; tests count its calls.
    ///   - hooks: test seams on the slot threads.
    ///   - clock: stamps each item's submit, start and end for ``stats``, in nanoseconds.
    ///   - lane: the lane its trace slices name; nil for a test's lane.
    ///   - trace: the runtime its `task.run` slices go to.
    init(label: String, policy: Policy, mayBlock: Bool, caps: [LaneCap: Int] = [:],
         compensation: MayBlockCompensation? = nil, hangWatching: HangWatching? = nil,
         qosOverride: ThreadQoSOverride = .system, hooks: Hooks = .none,
         clock: @escaping @Sendable () -> UInt64 = { LaneStats.uptimeNanos() }, lane: BlockingLane? = nil,
         trace: TraceRuntime = .shared) {
        self.policy = policy
        self.lane = lane
        self.trace = trace
        self.qosOverride = qosOverride
        self.hooks = hooks
        self.clock = clock
        stats = LaneStats()
        self.mayBlock = mayBlock
        self.compensation = compensation
        // timer-class-allow: off main: the lane's may-block recheck runs on the lane's clock and never wakes the main thread
        recheck = compensation.map { DemandTimer(owner: "\(label).may-block", clock: $0.clock) }
        var names: [String] = [], levelSlots: [Range<Int>] = [], reserved = 0
        switch policy {
        case .perPriority(let widths):
            for level in WorkPriority.allCases {
                let width = max(1, widths.indices.contains(level.rawValue) ? widths[level.rawValue] : 1)
                levelSlots.append(names.count..<(names.count + width))
                names += (0..<width).map { "\(label).\(level).\($0)" }
            }
        case .shared(let width, let wanted):
            names = (0..<max(1, width)).map { "\(label).\($0)" }
            reserved = min(max(0, wanted), names.count - 1)
        }
        self.levelSlots = levelSlots
        // The item's QoS (`.enforceQoS`) sets the thread's QoS; the queue itself has none.
        slots = names.map { DispatchQueue(label: $0, qos: .unspecified, autoreleaseFrequency: .workItem) }
        hangWatched = hangWatching.map { watching in
            names.map { _ in HangWatchedLane(watching.name, deadline: watching.deadline, on: watching.watch) }
        } ?? []
        state = Mutex(State(running: Array(repeating: nil, count: names.count), reserved: reserved,
                            caps: caps.mapValues { max(1, $0) }, mayBlockThreshold: compensation?.threshold))
    }

    deinit {
        for slot in hangWatched { slot.unregister() }
    }

    /// What ``submit(_:at:unless:)`` did with an item.
    enum Submitted {
        /// Not taken: cancelled, or the lane is shut down.
        case refused
        /// It started on a free slot at once.
        case started
        /// It waits for a slot, at this priority.
        case queued(WorkPriority)
    }

    /// Where a submitted item's `task.run` queue wait starts.
    enum PostStamp {
        /// At this submit: the item is posted to the lane now.
        case atSubmit
        /// At an earlier post (a ``WorkSequence`` item, which waited behind its sequence first): the ``postStamp()``
        /// taken then, nil when the `task` category was off then.
        case taken(UInt64?)
    }

    /// The trace clock now while the `task` category records, else nil: the stamp an item takes at its post, from
    /// which its `task.run` slice counts the queue wait. One relaxed load while the category is off.
    func postStamp() -> UInt64? {
        trace.isEnabled(.task) ? trace.nowNanos() : nil
    }

    /// Queues `job` at `priority`. Refused when `cancelled` holds (read under the lock, so a concurrent
    /// ``remove(_:)`` either finds the item or makes this refuse it) or the lane is shut down and `job`
    /// may not run any more (only a ``ShutdownBehavior/blockShutdown`` item is still taken).
    /// A `posted` item (nobody awaits it) at ``WorkPriority/idle`` or ``WorkPriority/bestEffort`` waits
    /// while a fence is up. An item of the `cap` class waits while the class runs its cap. Only a `raisable` item
    /// (a ``WorkHandle``'s) gets a QoS override when ``raise(_:to:awaited:)`` finds it running; the others skip
    /// recording their thread, except a block-shutdown item below user-blocking, which ``close()`` raises. After
    /// ``close()`` a block-shutdown item starts at `.userInitiated`; on a `shared` lane it is queued at
    /// ``WorkPriority/userBlocking`` (quit waits for it).
    /// A `delegate` makes the item one run of a yieldable job, which the lane asks to yield while it runs.
    /// `postStamp` says where its `task.run` queue wait starts.
    func submit(_ job: LaneJob, at priority: WorkPriority, posted: Bool, cap: LaneCap? = nil, raisable: Bool = false,
                delegate: JobDelegate? = nil, postStamp stamp: PostStamp = .atSubmit,
                unless cancelled: () -> Bool) -> Submitted {
        let queuedAt = clock()
        let tracedPost = switch stamp {
        case .atSubmit: postStamp()
        case .taken(let stamped): stamped
        }
        let taken: (starts: [Start], level: WorkPriority)? = state.withLock { state in
            if cancelled() || (state.closed && job.shutdown != .blockShutdown) { return nil }
            let level = state.closed && liftsBlockItems ? WorkPriority.userBlocking : priority
            state.pending[level.rawValue].append(Entry(job: job, posted: posted, cap: cap, raisable: raisable,
                                                       queuedAt: queuedAt, delegate: delegate,
                                                       tracedPost: tracedPost))
            return (pump(&state), level)
        }
        return launched(taken, job)
    }

    /// Queues the rest of a yieldable job that yielded, as the next run `job` (same id), in its old place: before
    /// every item at its level posted after the job started (by id), as Chrome sorts a re-enqueued job by its
    /// original queue time (base/task/thread_pool/job_task_source.cc, `GetSortKey`). Refused when `cancelled`
    /// holds (read under the lock, as in ``submit(_:at:posted:cap:raisable:delegate:postStamp:unless:)``), or after
    /// ``close()`` for any job but a ``ShutdownBehavior/blockShutdown`` one, the rule submit and ``close()`` use:
    /// Chrome's `TaskTracker::BeforeRunTask` (base/task/thread_pool/task_tracker.cc) refuses every later run of a
    /// CONTINUE_ON_SHUTDOWN or SKIP_ON_SHUTDOWN task source once shutdown has started. So after ``close()`` only a
    /// block-shutdown rest is queued, and only it moves to the user-blocking list on a `shared` lane.
    func requeue(_ job: LaneJob, at priority: WorkPriority, delegate: JobDelegate, unless cancelled: () -> Bool) -> Submitted {
        let queuedAt = clock()
        let tracedPost = postStamp()
        let taken: (starts: [Start], level: WorkPriority)? = state.withLock { state in
            if cancelled() || (state.closed && job.shutdown != .blockShutdown) { return nil }
            let level = state.closed && liftsBlockItems ? WorkPriority.userBlocking : priority
            let list = state.pending[level.rawValue]
            state.pending[level.rawValue].insert(Entry(job: job, posted: false, cap: nil, raisable: false,
                                                       queuedAt: queuedAt, delegate: delegate,
                                                       tracedPost: tracedPost),
                                                 at: list.firstIndex { $0.job.id > job.id } ?? list.endIndex)
            return (pump(&state), level)
        }
        return launched(taken, job)
    }

    /// Launches what a submit started and says what became of `job`.
    private func launched(_ taken: (starts: [Start], level: WorkPriority)?, _ job: LaneJob) -> Submitted {
        guard let taken else { return .refused }
        launch(taken.starts)
        return taken.starts.contains { $0.job.id == job.id } ? .started : .queued(taken.level)
    }

    /// Moves queued item `id` to `level` and sets whether it is `posted`, at once: at its new level it goes before
    /// every item posted after it (by id), and a move that keeps its level keeps its place, so a raise never puts it
    /// behind later work. Chrome orders a raised sequence by its oldest task's queue time
    /// (base/task/thread_pool/sequence.cc, `Sequence::GetSortKey`). False when the item is not queued (it started,
    /// or shutdown dropped it).
    @discardableResult
    func move(_ id: UInt64, to level: WorkPriority, posted: Bool) -> Bool {
        let starts = state.withLock { state -> [Start]? in
            for from in WorkPriority.allCases {
                guard let index = state.pending[from.rawValue].firstIndex(where: { $0.job.id == id }) else { continue }
                if from == level {
                    state.pending[from.rawValue][index].posted = posted
                } else {
                    var entry = state.pending[from.rawValue].remove(at: index)
                    entry.posted = posted
                    let list = state.pending[level.rawValue]
                    state.pending[level.rawValue].insert(entry, at: list.firstIndex { $0.job.id > id } ?? list.endIndex)
                }
                return pump(&state)
            }
            return nil
        }
        guard let starts else { return false }
        launch(starts)
        return true
    }

    /// Takes item `id` out of the queue when it has not started; returns it so the caller abandons it.
    func remove(_ id: UInt64) -> LaneJob? {
        state.withLock { state in
            guard let found = state.locate(id) else { return nil }
            return state.pending[found.level.rawValue].remove(at: found.index).job
        }
    }

    /// Raises item `id` to `priority`. A queued item moves to `priority`'s list, in post order (Chrome's
    /// `UpdateableSequencedTaskRunner::UpdatePriority`, base/task/updateable_sequenced_task_runner.h, and the
    /// priority-then-post-time `TaskSourceSortKey`). A running item gets an override of its slot thread at
    /// `priority`'s QoS until it ends (`pthread_override_qos_class_start_np`, as Chrome's `ScopedBoostablePriority`,
    /// base/threading/scoped_thread_priority.h). An equal or lower `priority`, or a finished item, changes
    /// nothing. `awaited` (someone now awaits the item) also frees a queued one from the best-effort fence.
    func raise(_ id: UInt64, to priority: WorkPriority, awaited: Bool) {
        let starts = state.withLock { state -> [Start] in
            if let slot = state.running.firstIndex(where: { $0?.id == id }) {
                boost(slot, to: priority, in: &state)
                return []
            }
            guard let (level, index) = state.locate(id) else { return [] }
            let frees = awaited && state.pending[level.rawValue][index].posted
            guard priority > level || frees else { return [] }
            if awaited { state.pending[level.rawValue][index].posted = false }
            if priority > level {
                let entry = state.pending[level.rawValue].remove(at: index)
                let at = state.pending[priority.rawValue].firstIndex { $0.job.id > id } ?? state.pending[priority.rawValue].endIndex
                state.pending[priority.rawValue].insert(entry, at: at)
            }
            return pump(&state)
        }
        launch(starts)
    }

    /// Starts an override at `priority` on the thread of the raisable item running on `slot`, when that is above its
    /// level and every earlier raise; before the item has its thread, ``began(slot:)`` starts it. The start runs under
    /// the lock: the lock is what keeps the target thread inside this item until the override is recorded.
    private func boost(_ slot: Int, to priority: WorkPriority, in state: inout State) {
        guard var running = state.running[slot], running.raisable,
              priority > max(running.priority, running.raised ?? running.priority) else {
            return
        }
        running.raised = priority
        if running.thread != 0, let token = qosOverride.start(running.thread, priority) { running.overrides.append(token) }
        state.running[slot] = running
    }

    /// Stops taking items other than ``ShutdownBehavior/blockShutdown`` ones, lifts the best-effort
    /// fence, raises block-shutdown work to `.userInitiated` (each queued one starts at it; each running one
    /// below it gets one override; on a `shared` lane the queued ones move to the user-blocking list, the highest
    /// level first and in order within a level), and returns the pending items that shutdown drops. A second
    /// call drops and raises nothing more.
    func close() -> [LaneJob] {
        let result = state.withLock { state -> (dropped: [LaneJob], starts: [Start]) in
            state.closed = true
            var dropped: [LaneJob] = []
            var lifted: [Entry] = []
            for level in WorkPriority.allCases.reversed() {
                let (keep, drop) = state.pending[level.rawValue].reduce(into: ([Entry](), [Entry]())) { split, entry in
                    if entry.job.shutdown == .blockShutdown { split.0.append(entry) } else { split.1.append(entry) }
                }
                dropped += drop.map(\.job)
                if liftsBlockItems && level < .userBlocking {
                    state.pending[level.rawValue] = []
                    lifted += keep
                } else {
                    state.pending[level.rawValue] = keep
                }
            }
            state.pending[WorkPriority.userBlocking.rawValue] += lifted
            for slot in state.running.indices where state.running[slot]?.blockShutdown == true {
                boost(slot, to: .userBlocking, in: &state)
            }
            // A running skip-on-shutdown job stops at its next chunk: requeue() refuses its rest.
            for case let busy? in state.running where busy.skipsOnShutdown { busy.delegate?.askToYield() }
            return (dropped, pump(&state))
        }
        // Closing lifts the fence: block-shutdown items it held start now.
        launch(result.starts)
        return result.dropped
    }

    /// Whether shutdown moves block-shutdown items to the user-blocking list: only a `shared` lane, which keeps
    /// no per-level order; a `perPriority` lane's levels keep their own slots (``BlockingLane/files``).
    private var liftsBlockItems: Bool {
        if case .shared = policy { return true }
        return false
    }

    /// Raises the best-effort fence one level. Items that already run finish; posted
    /// ``WorkPriority/idle`` and ``WorkPriority/bestEffort`` items wait until every fence is down.
    func fence() {
        state.withLock { $0.fences += 1 }
    }

    /// Lowers the fence one level; at zero, the held items start in post order within each level.
    /// A call with no fence up does nothing.
    func unfence() {
        let starts = state.withLock { state -> [Start] in
            guard state.fences > 0 else { return [] }
            state.fences -= 1
            return state.fenced ? [] : pump(&state)
        }
        launch(starts)
    }

    /// The items to start now: for each free slot, the next item it may run. On a lane with a may-block threshold,
    /// sets the recheck timer when the caps hold a low item.
    private func pump(_ state: inout State) -> [Start] {
        if let compensation { state.now = compensation.elapsed() }
        defer { armRecheck(&state) }
        var starts: [Start] = []
        switch policy {
        case .perPriority:
            for level in WorkPriority.allCases {
                for slot in levelSlots[level.rawValue] where state.running[slot] == nil {
                    guard let index = state.next(at: level, full: state.fullCaps) else { break }
                    starts.append(claim(level, index, slot: slot, in: &state))
                }
            }
        case .shared:
            // Each pick marks its slot busy first, so the next pick sees the reserve and the caps it took.
            for slot in state.running.indices where state.running[slot] == nil {
                guard let pick = state.highest() else { break }
                starts.append(claim(pick.level, pick.index, slot: slot, in: &state))
            }
            askYields(&state)
        }
        return starts
    }

    /// Asks running job runs to yield to the items above best effort that still wait once every free slot took what
    /// it may: for each such item, highest level first, one job run below it, unless a run already asked will free
    /// its slot. Chrome's `ThreadGroup::ShouldYield` and `max_allowed_sort_key_` (base/task/thread_pool/thread_group.cc):
    /// never to best-effort work, never to work of the job's own level. At most one pass per running slot.
    private func askYields(_ state: inout State) {
        guard state.running.contains(where: { $0?.delegate != nil }) else { return }
        let full = state.fullCaps
        var freeing = state.running.count(where: { $0?.yieldAsked == true })
        for level in WorkPriority.allCases.reversed() where level > .bestEffort {
            for entry in state.pending[level.rawValue] where entry.cap.map({ !full.contains($0) }) ?? true {
                if freeing > 0 {
                    freeing -= 1
                    continue
                }
                guard let slot = state.yieldCandidate(below: level) else { return }
                state.running[slot]?.yieldAsked = true
                state.running[slot]?.delegate?.askToYield()
            }
        }
    }

    /// Takes the pending item `index` at `level` and marks `slot` busy with it.
    private func claim(_ level: WorkPriority, _ index: Int, slot: Int, in state: inout State) -> Start {
        let entry = state.pending[level.rawValue].remove(at: index)
        let blockShutdown = entry.job.shutdown == .blockShutdown
        // A block-shutdown item that starts below user-blocking before shutdown records its thread, so close() can
        // raise it.
        let raisable = entry.raisable || (blockShutdown && !state.closed && level < .userBlocking)
        // A job run starts unasked; a cancel stays (JobDelegate.rearm).
        entry.delegate?.rearm()
        state.running[slot] = Running(id: entry.job.id, priority: level, cap: entry.cap, started: state.now,
                                      raisable: raisable, blockShutdown: blockShutdown, delegate: entry.delegate,
                                      skipsOnShutdown: entry.job.shutdown == .skipOnShutdown)
        return Start(job: entry.job, slot: slot, priority: level, raisable: raisable, closed: state.closed,
                     queuedAt: entry.queuedAt, tracedPost: entry.tracedPost)
    }

    /// Sets the recheck timer to the next threshold crossing when that is earlier than the one it is set to.
    /// Under the lane's lock, so the timer always holds the earliest crossing (the timer's own lock is taken
    /// inside this one and never the other way round: its fire runs ``recount()`` with its lock released).
    private func armRecheck(_ state: inout State) {
        guard let recheck, let at = state.nextRecount() else { return }
        if let armed = state.recheckAt, armed <= at { return }
        state.recheckAt = at
        recheck.schedule(after: at - state.now) { [weak self] in self?.recount() }
    }

    /// The recheck timer's fire: a running low item passed the threshold, so a held one may start.
    private func recount() {
        let starts = state.withLock { state -> [Start] in
            state.recheckAt = nil
            return pump(&state)
        }
        launch(starts)
    }

    private func launch(_ starts: [Start]) {
        for start in starts {
            slots[start.slot].async(qos: start.qos, flags: .enforceQoS) { [self] in runOnSlot(start) }
        }
    }

    /// One item on its slot thread: its start and end stamps (the item's ``LaneJob`` reports them too, so nothing
    /// else reads the clock for it), its body, its ``stats``, then the next items. An item abandoned before it
    /// started counts nothing.
    // perf-hot: 100ns lane-item
    private func runOnSlot(_ start: Start) {
        hooks.beforeBegin(start.slot)
        if start.raisable { began(slot: start.slot) }
        let started = clock()
        // Chrome's task_tracker.cc runs a MayBlock() task with blocking allowed and any other task under
        // ScopedDisallowBlocking, and a task without WithBaseSyncPrimitives() under
        // ScopedDisallowBaseSyncPrimitives: a files or system item may block but not wait on a sync primitive
        // (a lane-sync site), a cpu item may not block.
        let ended: UInt64?
        if mayBlock {
            ended = BlockingContext.runAsLane { run(start, startedAt: started) }
        } else {
            ended = BlockingContext.runAsCPULane { run(start, startedAt: started) }
        }
        if let ended {
            stats.record(start.priority, waitNanos: started > start.queuedAt ? started - start.queuedAt : 0,
                         runNanos: ended > started ? ended - started : 0)
        }
        finish(slot: start.slot, raisable: start.raisable)
    }

    /// Runs the started job on its slot's thread at the level the slot runs it at, inside its `task.run` slice when
    /// it was posted while the trace recorded, with the flow-in of its post's `task.post` (``TaskTrace``) first in
    /// the slice; its end stamp, or nil when it was abandoned first.
    private func run(_ start: Start, startedAt started: UInt64) -> UInt64? {
        guard let tracedPost = start.tracedPost else { return watched(start, startedAt: started) }
        let waitedMicros = (trace.nowNanos() &- tracedPost) / 1_000
        return trace.interval(.taskRun, arg0: Self.traceSite(lane: lane, priority: start.priority), arg1: waitedMicros) {
            start.job.traceArrival()
            return watched(start, startedAt: started)
        }
    }

    /// A `task.run` begin's arg0: the ``BlockingLane`` in bits 8-15 (0xFF for a lane made without one, a test's) and
    /// the ``WorkPriority`` in bits 0-7.
    static func traceSite(lane: BlockingLane?, priority: WorkPriority) -> UInt64 {
        UInt64(lane.map { UInt8($0.rawValue) } ?? 0xFF) << 8 | UInt64(priority.rawValue)
    }

    /// Runs the started job inside the slot's hang scope when the lane is watched; its end stamp, or nil when it was
    /// abandoned first.
    private func watched(_ start: Start, startedAt started: UInt64) -> UInt64? {
        guard hangWatched.indices.contains(start.slot) else {
            return start.job.execute(at: start.priority, startedAt: started, clock: clock)
        }
        return hangWatched[start.slot].run { start.job.execute(at: start.priority, startedAt: started, clock: clock) }
    }

    /// Records the thread the raisable item on `slot` runs on, and starts the override a raise asked for before it
    /// had one. That start runs outside the lock: this is the item's own thread, so it lives until
    /// ``finish(slot:raisable:)``, which runs after this on the same thread. A raise between the two locks sees the
    /// thread and starts its own override only for a higher level.
    private func began(slot: Int) {
        let thread = pthread_mach_thread_np(pthread_self())
        let raised = state.withLock { state -> WorkPriority? in
            state.running[slot]?.thread = thread
            return state.running[slot]?.raised
        }
        guard let raised, let token = qosOverride.start(thread, raised) else { return }
        state.withLock { $0.running[slot]?.overrides.append(token) }
    }

    /// Frees `slot`, ends the overrides its raisable item got (on its own thread, before the slot runs anything else)
    /// and starts what may run now.
    private func finish(slot: Int, raisable: Bool) {
        let (overrides, starts) = state.withLock { state -> ([ThreadQoSOverride.Token], [Start]) in
            let overrides = raisable ? state.running[slot]?.overrides ?? [] : []
            state.running[slot] = nil
            return (overrides, pump(&state))
        }
        for token in overrides { qosOverride.end(token) }
        launch(starts)
    }
}
