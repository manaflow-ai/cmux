import Foundation

/// Backs a REPL session's `setTimeout`/`setInterval` with one cancellable
/// clock sleep.
///
/// Timers fire in deadline order, and timers sharing a deadline fire in the
/// order they were scheduled, matching the HTML timer ordering scripts rely
/// on. Only the earliest deadline has a sleeping task; scheduling an earlier
/// timer or cancelling the earliest one replaces that task. Deadlines live in
/// a min-heap, so scheduling, cancelling and finding the earliest take
/// O(log n): a cancelled or replaced timer's heap item stays until it
/// reaches the top (or the heap is rebuilt once it holds more than twice the
/// live timers). The clock is injected so tests advance time by hand.
///
/// A fired timer stays pending until `delivered(id:)` says its callback ran,
/// so a busy JS thread never collects more than one queued callback per
/// timer: an interval fires again only `interval` after its last callback
/// ran, and at most `maximumTimers` are scheduled or waiting to run.
public final class BrowserReplTimerScheduler<C: Clock>: @unchecked Sendable where C.Duration == Duration {
    private struct Entry {
        var deadline: C.Instant
        let interval: Duration?
        var sequence: UInt64
    }

    private let clock: C
    private let fire: @Sendable (Int) -> Void
    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    /// Every entry's deadline, and stale items of cancelled or replaced ones.
    private var heap = DeadlineHeap<C.Instant>()
    /// Fired timers whose callbacks have not run yet.
    private var awaitingDelivery: Set<Int> = []
    /// Intervals waiting for their last callback to run, with their interval.
    private var parkedIntervals: [Int: Duration] = [:]
    private let maximumTimers: Int
    private var nextSequence: UInt64 = 0
    private var pump: Task<Void, Never>?
    private var pumpDeadline: C.Instant?
    private var generation: UInt64 = 0
    private var isInvalidated = false

    /// Creates a scheduler.
    /// - Parameters:
    ///   - clock: Time source; production passes `ContinuousClock()`.
    ///   - maximumTimers: The most timers scheduled or fired and not yet
    ///     delivered at once; `schedule` refuses more.
    ///   - fire: Called with each due timer id, in firing order, off any lock.
    public init(clock: C, maximumTimers: Int = .max, fire: @escaping @Sendable (Int) -> Void) {
        self.clock = clock
        self.maximumTimers = maximumTimers
        self.fire = fire
    }

    deinit {
        pump?.cancel()
    }

    /// Schedules or replaces timer `id`.
    /// - Parameters:
    ///   - id: Caller-owned timer id.
    ///   - delay: Delay before the first fire; negative values count as zero.
    ///   - repeating: Whether the timer re-arms with `delay` after each
    ///     delivered fire (at least one millisecond, as in browsers and Node).
    /// - Returns: `false`, scheduling nothing, when the scheduler is
    ///   invalidated or `maximumTimers` timers are already pending.
    @discardableResult
    public func schedule(id: Int, after delay: Duration, repeating: Bool) -> Bool {
        let clamped = delay < .zero ? .zero : delay
        lock.lock()
        let replacing = entries[id] != nil || awaitingDelivery.contains(id)
        guard !isInvalidated, replacing || entries.count + awaitingDelivery.count < maximumTimers else {
            lock.unlock()
            return false
        }
        awaitingDelivery.remove(id)
        parkedIntervals.removeValue(forKey: id)
        let interval: Duration? = repeating ? max(clamped, .milliseconds(1)) : nil
        insertLocked(id: id, entry: Entry(
            deadline: clock.now.advanced(by: clamped),
            interval: interval,
            sequence: takeSequence()
        ))
        rearmLocked()
        lock.unlock()
        return true
    }

    /// Cancels timer `id`. Unknown ids are ignored.
    public func cancel(id: Int) {
        lock.lock()
        entries.removeValue(forKey: id)
        awaitingDelivery.remove(id)
        parkedIntervals.removeValue(forKey: id)
        rearmLocked()
        lock.unlock()
    }

    /// Timer `id`'s fired callback ran: it no longer counts as pending, and
    /// an interval re-arms `interval` from now.
    public func delivered(id: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !isInvalidated, awaitingDelivery.remove(id) != nil else { return }
        if let interval = parkedIntervals.removeValue(forKey: id) {
            insertLocked(id: id, entry: Entry(deadline: clock.now.advanced(by: interval), interval: interval, sequence: takeSequence()))
            rearmLocked()
        }
    }

    /// Cancels every timer and stops accepting new ones.
    public func invalidate() {
        lock.lock()
        isInvalidated = true
        entries.removeAll()
        heap = DeadlineHeap()
        awaitingDelivery.removeAll()
        parkedIntervals.removeAll()
        pump?.cancel()
        pump = nil
        pumpDeadline = nil
        lock.unlock()
    }

    /// Whether timer `id` is scheduled (an interval waiting for its last
    /// callback to run counts).
    public func isScheduled(id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[id] != nil || parkedIntervals[id] != nil
    }

    /// Number of scheduled timers.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    private func takeSequence() -> UInt64 {
        nextSequence &+= 1
        return nextSequence
    }

    private func insertLocked(id: Int, entry: Entry) {
        entries[id] = entry
        heap.push(DeadlineHeap.Item(deadline: entry.deadline, sequence: entry.sequence, id: id))
    }

    /// Whether `item` is its timer's current entry. Call with `lock` held.
    private func isLive(_ item: DeadlineHeap<C.Instant>.Item) -> Bool {
        entries[item.id]?.sequence == item.sequence
    }

    /// The earliest live item, dropping stale ones above it. Call with `lock` held.
    private func earliestLocked() -> DeadlineHeap<C.Instant>.Item? {
        if heap.count > 2 * entries.count + 64 {
            heap = DeadlineHeap(entries.map { DeadlineHeap.Item(deadline: $0.value.deadline, sequence: $0.value.sequence, id: $0.key) })
        }
        while let top = heap.first, !isLive(top) { heap.popFirst() }
        return heap.first
    }

    private func rearmLocked() {
        let earliest = earliestLocked()?.deadline
        guard let earliest else {
            pump?.cancel()
            pump = nil
            pumpDeadline = nil
            return
        }
        if let pumpDeadline, pump != nil, pumpDeadline == earliest {
            return
        }
        pump?.cancel()
        generation &+= 1
        let token = generation
        pumpDeadline = earliest
        let clock = self.clock
        pump = Task { [weak self] in
            do {
                try await clock.sleep(until: earliest, tolerance: nil)
            } catch {
                return
            }
            self?.fireDue(generation: token)
        }
    }

    private func fireDue(generation token: UInt64) {
        lock.lock()
        guard token == generation, !isInvalidated else {
            lock.unlock()
            return
        }
        pump = nil
        pumpDeadline = nil
        let now = clock.now
        // In deadline order, ties in scheduling order.
        var due: [(Int, Entry)] = []
        while let top = earliestLocked(), !(now < top.deadline) {
            heap.popFirst()
            if let entry = entries[top.id] { due.append((top.id, entry)) }
        }
        for (id, entry) in due {
            // Parked until delivered(id:), so the timer has one callback queued at most.
            entries.removeValue(forKey: id)
            awaitingDelivery.insert(id)
            if let interval = entry.interval { parkedIntervals[id] = interval }
        }
        rearmLocked()
        lock.unlock()
        for (id, _) in due {
            fire(id)
        }
    }
}

/// A binary min-heap of timer deadlines, ordered by deadline, then by the
/// order the timers were scheduled.
private struct DeadlineHeap<Instant: InstantProtocol> {
    struct Item {
        let deadline: Instant
        let sequence: UInt64
        let id: Int
    }

    private var items: [Item] = []

    init() {}

    /// Builds a heap of `items` in O(n).
    init(_ items: [Item]) {
        self.items = items
        var index = items.count / 2
        while index > 0 {
            index -= 1
            siftDown(from: index)
        }
    }

    var count: Int { items.count }
    var first: Item? { items.first }

    mutating func push(_ item: Item) {
        items.append(item)
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.precedes(items[child], items[parent]) else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func popFirst() {
        guard !items.isEmpty else { return }
        items.swapAt(0, items.count - 1)
        items.removeLast()
        siftDown(from: 0)
    }

    private mutating func siftDown(from start: Int) {
        var parent = start
        while true {
            let left = 2 * parent + 1
            guard left < items.count else { return }
            var first = left
            if left + 1 < items.count, Self.precedes(items[left + 1], items[left]) { first = left + 1 }
            guard Self.precedes(items[first], items[parent]) else { return }
            items.swapAt(first, parent)
            parent = first
        }
    }

    private static func precedes(_ lhs: Item, _ rhs: Item) -> Bool {
        lhs.deadline == rhs.deadline ? lhs.sequence < rhs.sequence : lhs.deadline < rhs.deadline
    }
}
