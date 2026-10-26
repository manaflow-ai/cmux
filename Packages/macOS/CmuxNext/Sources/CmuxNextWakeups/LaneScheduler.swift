import CmuxNextCompat
import CmuxNextTrace
import Darwin
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
/// While a best-effort fence is up (``fence()``), a posted ``WorkPriority/idle`` or
/// ``WorkPriority/bestEffort`` item stays queued in post order; an item someone awaits still runs at its
/// own QoS. Chrome's `CanRunPolicy::kForegroundOnly` (base/task/thread_pool/thread_pool_impl.cc).
///
/// With a hang-watched lane, each item's run on its slot is one hang scope (Chrome's `WatchHangsInScope`
/// in `TaskTracker::RunTask`, base/task/thread_pool/task_tracker.cc); the wait for a slot is not.
///
/// ``raise(_:to:awaited:)`` moves a queued item up to a higher list, and gives a running one a QoS override
/// on its slot thread until it ends (Chrome's `UpdateableSequencedTaskRunner::UpdatePriority` and
/// `ScopedBoostablePriority`).
final class LaneScheduler: Sendable {
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
        /// A ``WorkHandle`` item, which ``raise(_:to:awaited:)`` may boost while it runs.
        var raisable: Bool
    }

    /// What one busy slot runs: its item, level and capped class, and the overrides a raise started on it.
    private struct Running {
        var id: UInt64
        var priority: WorkPriority
        var cap: LaneCap?
        /// Whether a raise may boost it; only such an item records its thread.
        var raisable: Bool
        /// The slot thread's Mach port once a raisable item runs on it; 0 before.
        var thread: mach_port_t = 0
        /// The level a raise asked for above `priority`; nil when none did.
        var raised: WorkPriority?
        /// The overrides started on `thread`, ended when the item finishes.
        var overrides: [ThreadQoSOverride.Token] = []
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
        /// free, that is a user-blocking item of no capped class.
        func highest() -> (level: WorkPriority, index: Int)? {
            let full = fullCaps
            let open = unreservedFree
            for level in WorkPriority.allCases.reversed() {
                if level < .userBlocking && !open { return nil }
                if let index = next(at: level, full: full, uncappedOnly: !open) { return (level, index) }
            }
            return nil
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
    }

    let policy: Policy
    /// Whether the lane's items may block (Chrome's `MayBlock()` trait): files and system may, cpu may not.
    private let mayBlock: Bool
    /// The lane's hang-watch slot; each item runs in one scope of it. nil watches nothing.
    private let hangWatched: HangWatchedLane?
    private let slots: [DispatchQueue]
    /// Starts and ends the QoS override a raise puts on a running item's slot thread.
    private let qosOverride: ThreadQoSOverride
    // concurrency-allow: a short non-blocking critical section over the pending lists, taken from lane threads, cancel handlers and submitters that must not await (lock carve-out).
    private let state: Mutex<State>

    /// - Parameters:
    ///   - caps: how many items of each ``LaneCap`` class run at once; a class without an entry is not capped.
    ///   - qosOverride: the override a raise of a running item starts; tests count its calls.
    init(label: String, policy: Policy, mayBlock: Bool, caps: [LaneCap: Int] = [:], hangWatched: HangWatchedLane? = nil,
         qosOverride: ThreadQoSOverride = .system) {
        self.policy = policy
        self.qosOverride = qosOverride
        self.mayBlock = mayBlock
        self.hangWatched = hangWatched
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
                            caps: caps.mapValues { max(1, $0) }))
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
    /// while a fence is up. An item of the `cap` class waits while the class runs its cap. Only a `raisable` item
    /// (a ``WorkHandle``'s) gets a QoS override when ``raise(_:to:awaited:)`` finds it running; the others skip
    /// recording their thread.
    func submit(_ job: LaneJob, at priority: WorkPriority, posted: Bool, cap: LaneCap? = nil, raisable: Bool = false,
                unless cancelled: () -> Bool) -> Submitted {
        let taken: (starts: [Start], level: WorkPriority)? = state.withLock { state in
            if cancelled() || (state.closed && job.shutdown != .blockShutdown) { return nil }
            let level = priority
            state.pending[level.rawValue].append(Entry(job: job, posted: posted, cap: cap, raisable: raisable))
            return (pump(&state), level)
        }
        guard let taken else { return .refused }
        launch(taken.starts)
        return taken.starts.contains { $0.job.id == job.id } ? .started : .queued(taken.level)
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

    /// The items to start now: for each free slot, the next item it may run.
    private func pump(_ state: inout State) -> [Start] {
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
        state.running[slot] = Running(id: entry.job.id, priority: level, cap: entry.cap, raisable: entry.raisable)
        return Start(job: entry.job, slot: slot, priority: level, raisable: entry.raisable)
    }

    private func launch(_ starts: [Start]) {
        for start in starts {
            slots[start.slot].async(qos: start.priority.qos, flags: .enforceQoS) { [self] in
                if start.raisable { began(slot: start.slot) }
                // Chrome's task_tracker.cc runs a MayBlock() task with blocking allowed and any other task
                // under ScopedDisallowBlocking: a files or system item may block, a cpu item may not.
                if mayBlock {
                    BlockingContext.runAsLane { run(start.job) }
                } else {
                    BlockingContext.runAsCPULane { run(start.job) }
                }
                finish(slot: start.slot, raisable: start.raisable)
            }
        }
    }

    /// Runs `job` on this slot's thread, inside the lane's hang scope when it has one.
    private func run(_ job: LaneJob) {
        guard let hangWatched else { return job.execute() }
        hangWatched.run { job.execute() }
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
