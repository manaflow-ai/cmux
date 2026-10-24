import CmuxNextCompat
import Dispatch

/// The queue of one ``BlockingLane``: which item runs next, on which slot, at which QoS.
///
/// A slot is a serial `DispatchQueue` that runs one item at a time at the item's QoS (`.enforceQoS`);
/// GCD makes a thread only while a slot has work. `perPriority` lanes (files, system) have one slot per
/// ``WorkPriority``, so each priority is serial and a best-effort write never sits in front of a
/// user-blocking read. A `shared` lane (cpu) has `width` slots for every priority and starts the
/// highest-priority pending item first.
///
/// Boost: a pending item moves to its new priority's queue (and slot); a running item's slot gets an
/// empty item at the new QoS, which makes GCD raise the thread that runs it (async QoS override).
final class LaneScheduler: Sendable {
    enum Policy: Sendable {
        case perPriority
        case shared(width: Int)
    }

    private struct Running {
        var slot: Int
        var priority: WorkPriority
    }

    private struct State {
        var pending: [[LaneJob]] = Array(repeating: [], count: WorkPriority.allCases.count)
        var busy: [Bool]
        var running: [UInt64: Running] = [:]
        /// Boosts that arrived before their item was queued (an escalation racing the submit);
        /// ``submit(_:at:unless:)`` applies them and ``forget(_:)`` drops a stale one.
        var early: [UInt64: WorkPriority] = [:]
        var closed = false
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
    func submit(_ job: LaneJob, at priority: WorkPriority, unless cancelled: () -> Bool) -> Submitted {
        let taken: (starts: [Start], level: WorkPriority)? = state.withLock { state in
            let early = state.early.removeValue(forKey: job.id)
            if cancelled() || (state.closed && job.shutdown != .blockShutdown) { return nil }
            let level = max(priority, early ?? priority)
            state.pending[level.rawValue].append(job)
            return (pump(&state), level)
        }
        guard let taken else { return .refused }
        launch(taken.starts)
        return taken.starts.contains { $0.job.id == job.id } ? .started : .queued(taken.level)
    }

    /// Raises item `id` to `priority` when it runs below it: a pending item moves to that priority's
    /// queue, a running one has its thread raised.
    func boost(_ id: UInt64, to priority: WorkPriority) {
        enum Effect { case none, started([Start]), override(Int) }
        let effect: Effect = state.withLock { state in
            if var running = state.running[id] {
                guard running.priority < priority else { return .none }
                running.priority = priority
                state.running[id] = running
                return .override(running.slot)
            }
            for level in WorkPriority.allCases where level < priority {
                guard let index = state.pending[level.rawValue].firstIndex(where: { $0.id == id }) else { continue }
                let job = state.pending[level.rawValue].remove(at: index)
                state.pending[priority.rawValue].append(job)
                return .started(pump(&state))
            }
            if !state.pending[priority.rawValue].contains(where: { $0.id == id }) {
                state.early[id] = max(priority, state.early[id] ?? priority)
            }
            return .none
        }
        switch effect {
        case .none: break
        case .started(let starts): launch(starts)
        case .override(let slot): slots[slot].async(qos: priority.qos, flags: .enforceQoS) {}
        }
    }

    /// Drops a boost of item `id` that never met its item (the caller's wait has ended).
    func forget(_ id: UInt64) {
        state.withLock { _ = $0.early.removeValue(forKey: id) }
    }

    /// Takes item `id` out of the queue when it has not started; returns it so the caller abandons it.
    func remove(_ id: UInt64) -> LaneJob? {
        state.withLock { state in
            for level in WorkPriority.allCases {
                if let index = state.pending[level.rawValue].firstIndex(where: { $0.id == id }) {
                    return state.pending[level.rawValue].remove(at: index)
                }
            }
            return nil
        }
    }

    /// Stops taking items other than ``ShutdownBehavior/blockShutdown`` ones and returns the pending
    /// items that shutdown drops.
    func close() -> [LaneJob] {
        state.withLock { state in
            state.closed = true
            var dropped: [LaneJob] = []
            for level in WorkPriority.allCases {
                let (keep, drop) = state.pending[level.rawValue].reduce(into: ([LaneJob](), [LaneJob]())) { split, job in
                    if job.shutdown == .blockShutdown { split.0.append(job) } else { split.1.append(job) }
                }
                state.pending[level.rawValue] = keep
                dropped += drop
            }
            return dropped
        }
    }

    /// The items to start now: for each free slot, the next item it may run.
    private func pump(_ state: inout State) -> [Start] {
        var starts: [Start] = []
        switch policy {
        case .perPriority:
            for level in WorkPriority.allCases where !state.busy[level.rawValue] && !state.pending[level.rawValue].isEmpty {
                starts.append(Start(job: state.pending[level.rawValue].removeFirst(), slot: level.rawValue, priority: level))
            }
        case .shared:
            for slot in state.busy.indices where !state.busy[slot] {
                guard let level = WorkPriority.allCases.reversed().first(where: { !state.pending[$0.rawValue].isEmpty })
                else { break }
                starts.append(Start(job: state.pending[level.rawValue].removeFirst(), slot: slot, priority: level))
            }
        }
        for start in starts {
            state.busy[start.slot] = true
            state.running[start.job.id] = Running(slot: start.slot, priority: start.priority)
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
            state.running[id] = nil
            state.busy[slot] = false
            return pump(&state)
        }
        launch(starts)
    }
}
