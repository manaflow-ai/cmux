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
        /// The entry may run from here on.
        let earliest: UInt64
        /// The entry must run by here.
        let latest: UInt64
        /// The boundary its fire date snaps up to, in ns; 0 for an exact (precise) entry.
        let grid: UInt64
        let owner: String
        let payload: Payload
    }

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

    /// When the timer must fire for the current top, in uptime ns, and the slack after that date the
    /// system may add to share the wake with other processes; nil when empty.
    ///
    /// `MessagePump::AdjustDelayedRunTime` (base/message_loop/message_pump.cc) under `kAlignWakeUps`:
    /// the top's earliest time snapped up to the next multiple of its grid (counted from uptime zero, so
    /// every queue in the process lands on the same ticks), clamped to its latest time. The top has the
    /// smallest latest time, so the fire is never after any entry's latest, and the tolerance runs to
    /// that latest time. An exact top fires at its own time with no tolerance.
    func wakeUp() -> (date: UInt64, tolerance: UInt64)? {
        guard let top = entries.first else { return nil }
        guard top.grid > 0 else { return (top.earliest, 0) }
        let date = min(Self.alignUp(top.earliest, grid: top.grid), top.latest)
        return (date, top.latest - date)
    }

    /// The least multiple of `grid` (> 0) at or after `time`, saturating at `UInt64.max`.
    static func alignUp(_ time: UInt64, grid: UInt64) -> UInt64 {
        let remainder = time % grid
        guard remainder != 0 else { return time }
        let (aligned, overflow) = (time - remainder).addingReportingOverflow(grid)
        return overflow ? .max : aligned
    }

    // MARK: - Binary heap

    private func before(_ lhs: Int, _ rhs: Int) -> Bool {
        let left = entries[lhs], right = entries[rhs]
        return (left.latest, left.id) < (right.latest, right.id)
    }

    private mutating func remove(at index: Int) -> Entry {
        let removed = entries[index]
        positions[removed.id] = nil
        let last = entries.count - 1
        if index != last {
            entries[index] = entries[last]
            positions[entries[index].id] = index
        }
        entries.removeLast()
        if index < entries.count {
            siftDown(index)
            siftUp(index)
        }
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
