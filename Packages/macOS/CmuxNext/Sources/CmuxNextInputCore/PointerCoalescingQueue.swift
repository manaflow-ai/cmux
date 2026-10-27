/// The continuous pointer input of one consumer waiting for its frame, in arrival order. An event
/// merges into the newest entry when it can (``PointerCoalescedInput/canMerge(_:)``) and starts a new
/// entry when it cannot, as Chromium's `MainThreadEventQueue` coalesces only with the queue's last
/// event, so a move, a drag and a scroll phase change keep their order.
///
/// A drained drag's sample storage goes back to a small pool that the next drag entries reuse, so a
/// steady drag allocates nothing per frame (p04-input.md rule 5).
///
/// ```swift
/// var queue = PointerCoalescingQueue()
/// queue.append(drag1)
/// queue.append(drag2)          // merges: one entry, coalescedCount 2
/// queue.drain { apply($0) }
/// ```
public struct PointerCoalescingQueue: Sendable {
    /// Emptied sample buffers kept for reuse: two per frame for a steady drag (leading and trailing).
    public static let spareSampleLimit = 4

    private var entries: [PointerCoalescedInput] = []
    private var spareSamples: [[PointerSample]] = []

    public init() {}

    /// Nothing is waiting.
    public var isEmpty: Bool { entries.isEmpty }

    /// The entries waiting, oldest first.
    public var pending: [PointerCoalescedInput] { entries }

    /// A drag is waiting (its fallback deadline is one frame, not the idle one).
    public var hasDrag: Bool { entries.contains { $0.kind == .drag } }

    /// Emptied drag sample buffers ready for reuse (debug and tests).
    public var spareSampleBuffers: Int { spareSamples.count }

    /// Adds `record`, merged into the newest entry when it can be; false when it is not continuous
    /// pointer input (the queue does not change).
    @discardableResult
    public mutating func append(_ record: InputEventRecord) -> Bool {
        if let last = entries.indices.last, entries[last].merge(record) { return true }
        guard let input = single(record) else { return false }
        entries.append(input)
        return true
    }

    /// A delivery of `record` alone, a drag's samples in a pooled buffer; nil when it is not continuous
    /// pointer input. Give it back with ``recycle(_:)`` after the delivery.
    public mutating func single(_ record: InputEventRecord) -> PointerCoalescedInput? {
        guard PointerCoalescedKind(record.type) == .drag else { return PointerCoalescedInput(record) }
        return PointerCoalescedInput(record, sampleBuffer: spareSamples.popLast() ?? [])
    }

    /// Hands every waiting entry to `body`, oldest first, and leaves the queue empty; each drag's
    /// sample storage goes back to the pool. `body` must not use this queue: a consumer drains a queue it
    /// swapped out, so input posted by `body` goes to its live one.
    public mutating func drain(_ body: (PointerCoalescedInput) -> Void) {
        for index in entries.indices {
            body(entries[index])
            var buffer = entries[index].takeSamples()
            keep(&buffer)
        }
        entries.removeAll(keepingCapacity: true)
    }

    /// Takes `input`'s sample storage back into the pool (after its delivery).
    public mutating func recycle(_ input: inout PointerCoalescedInput) {
        var buffer = input.takeSamples()
        keep(&buffer)
    }

    /// Drops every waiting entry (the pool keeps its buffers).
    public mutating func removeAll() {
        for index in entries.indices {
            var buffer = entries[index].takeSamples()
            keep(&buffer)
        }
        entries.removeAll(keepingCapacity: true)
    }

    /// Keeps `buffer`'s storage when it has some and the pool has room. A body that kept its delivery
    /// still shares the storage, so emptying it here makes a new one: no worse than not pooling.
    private mutating func keep(_ buffer: inout [PointerSample]) {
        guard buffer.capacity > 0, spareSamples.count < Self.spareSampleLimit else { return }
        buffer.removeAll(keepingCapacity: true)
        spareSamples.append(buffer)
    }
}
