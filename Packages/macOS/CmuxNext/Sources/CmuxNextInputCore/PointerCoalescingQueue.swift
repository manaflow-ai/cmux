/// The continuous pointer input of one consumer waiting for its frame, in arrival order. An event
/// merges into the newest entry when it can (``PointerCoalescedInput/canMerge(_:)``) and starts a new
/// entry when it cannot, as Chromium's `MainThreadEventQueue` coalesces only with the queue's last
/// event, so a move, a drag and a scroll phase change keep their order.
///
/// ```swift
/// var queue = PointerCoalescingQueue()
/// queue.append(drag1)
/// queue.append(drag2)          // merges: one entry, coalescedCount 2
/// for input in queue.drain() { apply(input) }
/// ```
public struct PointerCoalescingQueue: Sendable {
    private var entries: [PointerCoalescedInput] = []

    public init() {}

    /// Nothing is waiting.
    public var isEmpty: Bool { entries.isEmpty }

    /// The entries waiting, oldest first.
    public var pending: [PointerCoalescedInput] { entries }

    /// A drag is waiting (its fallback deadline is one frame, not the idle one).
    public var hasDrag: Bool { entries.contains { $0.kind == .drag } }

    /// Adds `record`, merged into the newest entry when it can be; false when it is not continuous
    /// pointer input (the queue does not change).
    @discardableResult
    public mutating func append(_ record: InputEventRecord) -> Bool {
        if let last = entries.indices.last, entries[last].merge(record) { return true }
        guard let input = PointerCoalescedInput(record) else { return false }
        entries.append(input)
        return true
    }

    /// Takes every waiting entry, oldest first, and leaves the queue empty.
    public mutating func drain() -> [PointerCoalescedInput] {
        defer { entries.removeAll(keepingCapacity: true) }
        return entries
    }

    /// Drops every waiting entry.
    public mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }
}
