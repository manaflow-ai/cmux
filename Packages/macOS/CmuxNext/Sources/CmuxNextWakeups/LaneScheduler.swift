import CmuxNextCompat
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
/// highest-priority pending item first; `reserved` of them run only ``WorkPriority/userBlocking`` items, so
/// lower work that hangs never holds the last slot a person waits for. An item of a ``LaneCap`` class runs only
/// while fewer than the class's cap run, so one hung kind (a resolver) leaves the lane's other slots to the
/// rest. Chrome's `PrioritizedDispatcher` (net/base/prioritized_dispatcher.h, `Limits::reserved_slots`), which
/// `HostResolverManager` runs its system DNS tasks through.
///
/// While a best-effort fence is up (``fence()``), a posted ``WorkPriority/idle`` or
/// ``WorkPriority/bestEffort`` item stays queued in post order; an item someone awaits still runs at its
/// own QoS. Chrome's `CanRunPolicy::kForegroundOnly` (base/task/thread_pool/thread_pool_impl.cc).
final class LaneScheduler: Sendable {
    enum Policy: Sendable {
        case perPriority
        /// `width` slots for every priority, `reserved` of them (at most `width - 1`) for user-blocking items only.
        case shared(width: Int, reserved: Int = 0)
    }

    private struct Entry {
        var job: LaneJob
        /// Nobody awaits it, so a best-effort fence holds it when its level is at most best effort.
        var posted: Bool
        /// The capped class it belongs to, if any.
        var cap: LaneCap?
    }

    /// What one busy slot runs: its level and capped class.
    private struct Running {
        var priority: WorkPriority
        var cap: LaneCap?
    }

    private struct State {
        var pending: [[Entry]] = Array(repeating: [], count: WorkPriority.allCases.count)
        /// Per slot: what it runs, nil while it is free.
        var running: [Running?]
        /// Slots only a ``WorkPriority/userBlocking`` item may take.
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

        /// Whether an item below ``WorkPriority/userBlocking`` may take a slot: the reserved ones stay free.
        var lowerMayStart: Bool {
            running.lazy.filter { $0.map { $0.priority < .userBlocking } ?? false }.count < running.count - reserved
        }

        /// The index of the first item at `level` that may start now, skipping the `full` capped classes.
        func next(at level: WorkPriority, full: Set<LaneCap>) -> Int? {
            let holdsPosted = fenced && level <= .bestEffort
            return pending[level.rawValue].firstIndex { entry in
                !(holdsPosted && entry.posted) && !(entry.cap.map { full.contains($0) } ?? false)
            }
        }

        /// The highest level with an item that may start now, and that item's index.
        func highest() -> (level: WorkPriority, index: Int)? {
            let full = fullCaps
            let lower = lowerMayStart
            for level in WorkPriority.allCases.reversed() {
                if level < .userBlocking && !lower { return nil }
                if let index = next(at: level, full: full) { return (level, index) }
            }
            return nil
        }
    }

    private struct Start {
        var job: LaneJob
        var slot: Int
        var priority: WorkPriority
    }

    let policy: Policy
    /// Whether the lane's items may block (Chrome's `MayBlock()` trait): files and system may, cpu may not.
    private let mayBlock: Bool
    private let slots: [DispatchQueue]
    // concurrency-allow: a short non-blocking critical section over the pending lists, taken from lane threads, cancel handlers and submitters that must not await (lock carve-out).
    private let state: Mutex<State>

    /// - Parameters:
    ///   - caps: how many items of each ``LaneCap`` class run at once; a class without an entry is not capped.
    init(label: String, policy: Policy, mayBlock: Bool, caps: [LaneCap: Int] = [:]) {
        self.policy = policy
        self.mayBlock = mayBlock
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
        let taken: (starts: [Start], level: WorkPriority)? = state.withLock { state in
            if cancelled() || (state.closed && job.shutdown != .blockShutdown) { return nil }
            let level = priority
            state.pending[level.rawValue].append(Entry(job: job, posted: posted, cap: cap))
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
        state.running[slot] = Running(priority: level, cap: entry.cap)
        return Start(job: entry.job, slot: slot, priority: level)
    }

    private func launch(_ starts: [Start]) {
        for start in starts {
            slots[start.slot].async(qos: start.priority.qos, flags: .enforceQoS) { [self] in
                // Chrome's task_tracker.cc runs a MayBlock() task with blocking allowed and any other task
                // under ScopedDisallowBlocking: a files or system item may block, a cpu item may not.
                if mayBlock {
                    BlockingContext.runAsLane { start.job.execute() }
                } else {
                    BlockingContext.runAsCPULane { start.job.execute() }
                }
                finish(start.job.id, slot: start.slot)
            }
        }
    }

    private func finish(_ id: UInt64, slot: Int) {
        let starts = state.withLock { state in
            state.running[slot] = nil
            return pump(&state)
        }
        launch(starts)
    }
}
