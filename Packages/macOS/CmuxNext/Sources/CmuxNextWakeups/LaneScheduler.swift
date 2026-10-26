import CmuxNextCompat
import Dispatch

/// The queue of one ``BlockingLane``: which item runs next, on which slot, at which QoS.
///
/// A slot is a serial `DispatchQueue` that runs one item at a time at the item's QoS (`.enforceQoS`);
/// GCD makes a thread only while a slot has work. A `perPriority` lane (files) has one slot per
/// ``WorkPriority``, so each priority is serial and a best-effort write never sits in front of a
/// user-blocking read. A `shared` lane (system, cpu) has `width` slots for every priority and starts the
/// highest-priority pending item first.
///
/// While a best-effort fence is up (``fence()``), a posted ``WorkPriority/idle`` or
/// ``WorkPriority/bestEffort`` item stays queued in post order; an item someone awaits still runs at its
/// own QoS. Chrome's `CanRunPolicy::kForegroundOnly` (base/task/thread_pool/thread_pool_impl.cc).
/// Raising the fence only counts: an item that already runs is not waited on. The app raises it
/// while launching (``StartupPhase/fenceBestEffort(_:)``) and the reveal lowers it.
final class LaneScheduler: Sendable {
    enum Policy: Sendable {
        case perPriority
        case shared(width: Int)
    }

    private struct Entry {
        var job: LaneJob
        /// Nobody awaits it, so a best-effort fence holds it when its level is at most best effort.
        var posted: Bool
    }

    private struct State {
        var pending: [[Entry]] = Array(repeating: [], count: WorkPriority.allCases.count)
        var busy: [Bool]
        var closed = false
        var fences = 0

        /// Shutdown lifts the fence so block-shutdown items finish (Chrome: `ThreadPoolImpl::Shutdown`
        /// sets `CanRunPolicy::kAll` once shutdown has started).
        var fenced: Bool { fences > 0 && !closed }

        /// The index of the first item at `level` that may start now.
        func next(at level: WorkPriority) -> Int? {
            let holdsPosted = fenced && level <= .bestEffort
            return pending[level.rawValue].firstIndex { !(holdsPosted && $0.posted) }
        }

        /// The highest level with an item that may start now, and that item's index.
        func highest() -> (level: WorkPriority, index: Int)? {
            for level in WorkPriority.allCases.reversed() {
                if let index = next(at: level) { return (level, index) }
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
    private let slots: [DispatchQueue]
    // concurrency-allow: a short non-blocking critical section over the pending lists, taken from lane threads, cancel handlers and submitters that must not await (lock carve-out).
    private let state: Mutex<State>

    init(label: String, policy: Policy) {
        self.policy = policy
        let names: [String] = switch policy {
        case .perPriority: WorkPriority.allCases.map { "\(label).\($0)" }
        case .shared(let width): (0..<max(1, width)).map { "\(label).\($0)" }
        }
        // The item's QoS (`.enforceQoS`) sets the thread's QoS; the queue itself has none.
        slots = names.map { DispatchQueue(label: $0, qos: .unspecified, autoreleaseFrequency: .workItem) }
        state = Mutex(State(busy: Array(repeating: false, count: names.count)))
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
    /// while a fence is up.
    func submit(_ job: LaneJob, at priority: WorkPriority, posted: Bool, unless cancelled: () -> Bool) -> Submitted {
        let taken: (starts: [Start], level: WorkPriority)? = state.withLock { state in
            if cancelled() || (state.closed && job.shutdown != .blockShutdown) { return nil }
            let level = priority
            state.pending[level.rawValue].append(Entry(job: job, posted: posted))
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
            for level in WorkPriority.allCases where !state.busy[level.rawValue] {
                guard let index = state.next(at: level) else { continue }
                let job = state.pending[level.rawValue].remove(at: index).job
                starts.append(Start(job: job, slot: level.rawValue, priority: level))
            }
        case .shared:
            for slot in state.busy.indices where !state.busy[slot] {
                guard let pick = state.highest() else { break }
                let job = state.pending[pick.level.rawValue].remove(at: pick.index).job
                starts.append(Start(job: job, slot: slot, priority: pick.level))
            }
        }
        for start in starts {
            state.busy[start.slot] = true
        }
        return starts
    }

    private func launch(_ starts: [Start]) {
        for start in starts {
            slots[start.slot].async(qos: start.priority.qos, flags: .enforceQoS) { [self] in
                start.job.execute()
                finish(start.job.id, slot: start.slot)
            }
        }
    }

    private func finish(_ id: UInt64, slot: Int) {
        let starts = state.withLock { state in
            state.busy[slot] = false
            return pump(&state)
        }
        launch(starts)
    }
}
