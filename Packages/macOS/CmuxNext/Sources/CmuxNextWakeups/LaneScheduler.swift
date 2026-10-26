import CmuxNextCompat
import CmuxNextTrace
import Dispatch

/// The queue of one ``BlockingLane``: which item runs next, on which slot, at which QoS.
///
/// A slot is a serial `DispatchQueue` that runs one item at a time at the item's QoS (`.enforceQoS`);
/// GCD makes a thread only while a slot has work. Each item of a lane that may block (files, system) runs with
/// its thread marked ``CmuxNextCompat/BlockingContext/lane``, so the blocking detector allows its seams; an item of
/// the cpu lane runs marked ``CmuxNextCompat/BlockingContext/cpuLane``, where a seam records a
/// ``CmuxNextCompat/BlockingKind/wrongLane`` site (Debug and bench-checks builds). A `perPriority` lane (files) has one slot per
/// ``WorkPriority``, so each priority is serial and a best-effort write never sits in front of a
/// user-blocking read. A `shared` lane (system, cpu) has `width` slots for every priority and starts the
/// highest-priority pending item first. `reserved` of them run only ``WorkPriority/userBlocking`` items of no
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
/// lane runs one item per level, inside both limits. On a lane with ``MayBlockCompensation`` (system), a low item
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
///
/// With a hang-watched lane, each item's run on its slot is one hang scope (Chrome's `WatchHangsInScope`
/// in `TaskTracker::RunTask`, base/task/thread_pool/task_tracker.cc); the wait for a slot is not.
///
/// Every item's queue wait (submit to start on its slot thread) and run time count in the lane's ``LaneStats`` at
/// the level it ran, in every build: three reads of the lane's clock (submit, start, end) and four relaxed atomic
/// adds per item, no lock (Chrome's `TaskTracker::RecordLatencyHistogram` counts post to start the same way).
final class LaneScheduler: Sendable {
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
            elapsed = Self.elapsedReader(clock)
        }

        private static func elapsedReader<C: Clock<Duration>>(_ clock: C) -> @Sendable () -> Duration {
            let start = clock.now
            return { start.duration(to: clock.now) }
        }
    }

    enum Policy: Sendable {
        case perPriority
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
        /// When it was submitted, on the lane's stats clock.
        var queuedAt: UInt64
    }

    /// What one busy slot runs: its level, capped class and start (on the lane's ``MayBlockCompensation`` clock).
    private struct Running {
        var priority: WorkPriority
        var cap: LaneCap?
        var started: Duration
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
    }

    private struct Start {
        var job: LaneJob
        var slot: Int
        var priority: WorkPriority
        var queuedAt: UInt64
    }

    let policy: Policy
    /// Whether the lane's items may block (Chrome's `MayBlock()` trait): files and system may, cpu may not.
    private let mayBlock: Bool
    /// The lane's hang-watch slot; each item runs in one scope of it. nil watches nothing.
    private let hangWatched: HangWatchedLane?
    private let slots: [DispatchQueue]
    /// The lane's clock for the may-block threshold; nil counts a low item for its whole run.
    private let compensation: MayBlockCompensation?
    /// Rechecks the caps when a held low item may start because a running one passed the threshold.
    private let recheck: DemandTimer?
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
    ///   - clock: stamps each item's submit, start and end for ``stats``, in nanoseconds.
    init(label: String, policy: Policy, mayBlock: Bool, caps: [LaneCap: Int] = [:],
         compensation: MayBlockCompensation? = nil, hangWatched: HangWatchedLane? = nil,
         clock: @escaping @Sendable () -> UInt64 = { LaneStats.uptimeNanos() }) {
        self.policy = policy
        self.clock = clock
        stats = LaneStats()
        self.mayBlock = mayBlock
        self.hangWatched = hangWatched
        self.compensation = compensation
        recheck = compensation.map { DemandTimer(owner: "\(label).may-block", clock: $0.clock) }
        let names: [String], reserved: Int
        switch policy {
        case .perPriority:
            names = WorkPriority.allCases.map { "\(label).\($0)" }
            reserved = 0
        case .shared(let width, let wanted):
            names = (0..<max(1, width)).map { "\(label).\($0)" }
            reserved = min(max(0, wanted), names.count - 1)
        }
        // The item's QoS (`.enforceQoS`) sets the thread's QoS; the queue itself has none.
        slots = names.map { DispatchQueue(label: $0, qos: .unspecified, autoreleaseFrequency: .workItem) }
        state = Mutex(State(running: Array(repeating: nil, count: names.count), reserved: reserved,
                            caps: caps.mapValues { max(1, $0) }, mayBlockThreshold: compensation?.threshold))
    }

    deinit {
        hangWatched?.unregister()
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

    /// Queues `job` at `priority`. Refused when `cancelled` holds (read under the lock, so a concurrent
    /// ``remove(_:)`` either finds the item or makes this refuse it) or the lane is shut down and `job`
    /// may not run any more (only a ``ShutdownBehavior/blockShutdown`` item is still taken).
    /// A `posted` item (nobody awaits it) at ``WorkPriority/idle`` or ``WorkPriority/bestEffort`` waits
    /// while a fence is up. An item of the `cap` class waits while the class runs its cap.
    func submit(_ job: LaneJob, at priority: WorkPriority, posted: Bool, cap: LaneCap? = nil,
                unless cancelled: () -> Bool) -> Submitted {
        let queuedAt = clock()
        let taken: (starts: [Start], level: WorkPriority)? = state.withLock { state in
            if cancelled() || (state.closed && job.shutdown != .blockShutdown) { return nil }
            let level = priority
            state.pending[level.rawValue].append(Entry(job: job, posted: posted, cap: cap, queuedAt: queuedAt))
            return (pump(&state), level)
        }
        guard let taken else { return .refused }
        launch(taken.starts)
        return taken.starts.contains { $0.job.id == job.id } ? .started : .queued(taken.level)
    }

    /// Takes item `id` out of the queue when it has not started; returns it so the caller abandons it.
    func remove(_ id: UInt64) -> LaneJob? {
        state.withLock { state in
            for level in WorkPriority.allCases {
                if let index = state.pending[level.rawValue].firstIndex(where: { $0.job.id == id }) {
                    return state.pending[level.rawValue].remove(at: index).job
                }
            }
            return nil
        }
    }

    /// Stops taking items other than ``ShutdownBehavior/blockShutdown`` ones, lifts the best-effort
    /// fence, and returns the pending items that shutdown drops.
    func close() -> [LaneJob] {
        let result = state.withLock { state -> (dropped: [LaneJob], starts: [Start]) in
            state.closed = true
            var dropped: [LaneJob] = []
            for level in WorkPriority.allCases {
                let (keep, drop) = state.pending[level.rawValue].reduce(into: ([Entry](), [Entry]())) { split, entry in
                    if entry.job.shutdown == .blockShutdown { split.0.append(entry) } else { split.1.append(entry) }
                }
                state.pending[level.rawValue] = keep
                dropped += drop.map(\.job)
            }
            return (dropped, pump(&state))
        }
        // Closing lifts the fence: block-shutdown items it held start now.
        launch(result.starts)
        return result.dropped
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
            for level in WorkPriority.allCases where state.running[level.rawValue] == nil {
                guard let index = state.next(at: level, full: state.fullCaps) else { continue }
                starts.append(claim(level, index, slot: level.rawValue, in: &state))
            }
        case .shared:
            // Each pick marks its slot busy first, so the next pick sees the reserve and the caps it took.
            for slot in state.running.indices where state.running[slot] == nil {
                guard let pick = state.highest() else { break }
                starts.append(claim(pick.level, pick.index, slot: slot, in: &state))
            }
        }
        return starts
    }

    /// Takes the pending item `index` at `level` and marks `slot` busy with it.
    private func claim(_ level: WorkPriority, _ index: Int, slot: Int, in state: inout State) -> Start {
        let entry = state.pending[level.rawValue].remove(at: index)
        state.running[slot] = Running(priority: level, cap: entry.cap, started: state.now)
        return Start(job: entry.job, slot: slot, priority: level, queuedAt: entry.queuedAt)
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
            slots[start.slot].async(qos: start.priority.qos, flags: .enforceQoS) { [self] in
                let started = clock()
                // Chrome's task_tracker.cc runs a MayBlock() task with blocking allowed and any other task
                // under ScopedDisallowBlocking: a files or system item may block, a cpu item may not.
                if mayBlock {
                    BlockingContext.runAsLane { run(start.job) }
                } else {
                    BlockingContext.runAsCPULane { run(start.job) }
                }
                let ended = clock()
                stats.record(start.priority, waitNanos: started > start.queuedAt ? started - start.queuedAt : 0,
                             runNanos: ended > started ? ended - started : 0)
                finish(start.job.id, slot: start.slot)
            }
        }
    }

    /// Runs `job` on this slot's thread, inside the lane's hang scope when it has one.
    private func run(_ job: LaneJob) {
        guard let hangWatched else { return job.execute() }
        hangWatched.run { job.execute() }
    }

    private func finish(_ id: UInt64, slot: Int) {
        let starts = state.withLock { state in
            state.running[slot] = nil
            return pump(&state)
        }
        launch(starts)
    }
}
