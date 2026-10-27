/// The pure deadline heap behind ``MainWakeUpQueue``: no lock, no clock, no run loop, so every
/// coalescing rule is a plain value test.
///
/// It is Chromium's `WakeUpQueue` (base/task/sequence_manager/wake_up_queue.h), which "aggregates
/// wake-ups from multiple TaskQueueImpl into a single wake-up": a heap ordered by each wake-up's
/// latest time, so the top is the deadline that must run first. Times are `CLOCK_UPTIME_RAW`
/// nanoseconds (the origin of Chromium's `TimeTicks` on macOS); the queue converts to
/// `CFAbsoluteTime` only when it arms its timer.
///
/// Insert, remove by id and pop are O(log n): `positions` maps each id to its slot.
struct MainWakeUpHeap<Payload> {
    struct Entry {
        let id: UInt64
        /// The requested deadline, in uptime ns.
        let deadline: UInt64
        /// The window around it: its policy, leeway and grid.
        let window: WakeLeeway
        /// The entry may run from here on.
        let earliest: UInt64
        /// The entry must run by here.
        let latest: UInt64
        /// It snaps to the heap's ``MainWakeUpHeap/alignment`` at wake time instead of its window's grid
        /// (``WakeLeeway/followsAlignment``): a flexible window on the sub-second alignment grid
        /// (``WakeLeeway``'s table). Whole-second, hidden (``WakeLeeway/hidden(delay:)``, a 1 s grid) and
        /// own-tolerance (``WakeLeeway/own(tolerance:delay:)``) windows keep their own.
        let followsAlignment: Bool
        let owner: String
        let payload: Payload

        init(id: UInt64, deadline: UInt64, window: WakeLeeway, owner: String, payload: Payload) {
            self.id = id
            self.deadline = deadline
            self.window = window
            self.earliest = window.earliest(deadline: deadline)
            self.latest = window.latest(deadline: deadline)
            self.followsAlignment = window.followsAlignment
            self.owner = owner
            self.payload = payload
        }

        /// When the entry fires if nothing else shares its wake: ``WakeLeeway/fireTime(deadline:)``.
        var fireTime: UInt64 { window.fireTime(deadline: deadline) }
    }

    /// The grid of entries that follow the alignment, in ns (> 0): 8 ms, 32 ms under Energy Saver. It is
    /// read at wake time, as `MessagePump::AdjustDelayedRunTime` reads the current leeway, so a change
    /// moves no entry: each keeps the latest time it was posted with.
    var alignment: UInt64 = WakeLeeway.defaultAlignment.nanosecondCount

    private var entries: [Entry] = []
    private var positions: [UInt64: Int] = [:]

    var count: Int { entries.count }
    /// The entry with the smallest latest time (ties: the older id).
    var top: Entry? { entries.first }

    mutating func insert(_ entry: Entry) {
        entries.append(entry)
        positions[entry.id] = entries.count - 1
        siftUp(entries.count - 1)
    }

    /// Removes the entry with `id`; nil when it already ran or was removed.
    @discardableResult
    mutating func remove(id: UInt64) -> Entry? {
        guard let index = positions[id] else { return nil }
        return remove(at: index)
    }

    /// Pops the top when it may run at `now` (its earliest time has passed). Only the top is looked at,
    /// as in `TaskQueueImpl::MoveReadyDelayedTasksToWorkQueue`, so an entry never runs before one that
    /// must run sooner.
    mutating func popDue(now: UInt64) -> Entry? {
        guard let top = entries.first, top.earliest <= now else { return nil }
        return remove(at: 0)
    }

    /// Pops the top when its fire time has passed: the release of a heap whose entries all share one
    /// window shape (the hidden one), where an entry runs only in a fire at or after its own boundary.
    /// With one shape the fire time grows with the latest time, so looking at the top alone is exact.
    mutating func popReleased(now: UInt64) -> Entry? {
        guard let top = entries.first, top.fireTime <= now else { return nil }
        return remove(at: 0)
    }

    /// When the timer must fire for the current top, in uptime ns, and the top's latest time (the end
    /// of the slack the system may add to share the wake with other processes); nil when empty.
    ///
    /// The date is the top's ``WakeLeeway/fireTime(deadline:)``: `MessagePump::AdjustDelayedRunTime`
    /// (base/message_loop/message_pump.cc) under `kAlignWakeUps`, the earliest time snapped up to the
    /// grid (``alignment`` for an entry that follows it) and clamped to the latest time. The top has the
    /// smallest latest time, so the fire is never after any entry's latest. An exact top fires at its own time.
    func wakeUp() -> (date: UInt64, latest: UInt64)? {
        guard let top = entries.first else { return nil }
        let date = top.followsAlignment
            ? top.window.fireTime(deadline: top.deadline, grid: .nanoseconds(max(alignment, 1)))
            : top.window.fireTime(deadline: top.deadline)
        return (date, top.latest)
    }

    // MARK: - Binary heap

    private func before(_ lhs: Int, _ rhs: Int) -> Bool {
        let left = entries[lhs], right = entries[rhs]
        return (left.latest, left.id) < (right.latest, right.id)
    }

    private mutating func remove(at index: Int) -> Entry {
        let removed = entries[index]
        positions[removed.id] = nil
        // The last entry fills the hole, unless the hole was the last slot.
        guard let last = entries.popLast(), index < entries.count else { return removed }
        entries[index] = last
        positions[last.id] = index
        siftDown(index)
        siftUp(index)
        return removed
    }

    private mutating func swapAt(_ lhs: Int, _ rhs: Int) {
        entries.swapAt(lhs, rhs)
        positions[entries[lhs].id] = lhs
        positions[entries[rhs].id] = rhs
    }

    private mutating func siftUp(_ start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard before(child, parent) else { return }
            swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ start: Int) {
        var parent = start
        while 2 * parent + 1 < entries.count {
            let left = 2 * parent + 1, right = left + 1
            var smallest = before(left, parent) ? left : parent
            if right < entries.count, before(right, smallest) { smallest = right }
            guard smallest != parent else { return }
            swapAt(parent, smallest)
            parent = smallest
        }
    }
}

extension MainWakeUpHeap.Entry: Sendable where Payload: Sendable {}
extension MainWakeUpHeap: Sendable where Payload: Sendable {}
