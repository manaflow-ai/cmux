/// The closed input latency slots, newest last: a fixed ring (256 by default) the thread that
/// closes slots (``InputLatencySlotTable/close(_:)``) writes in place, as CmuxNextActions'
/// `ActionSampleRing` does for action runs. A raw buffer, not an `Array`, so a write never copies.
///
/// Half-ring hand-off: ``append(_:)`` returns true once ``batchSize`` slots (half the ring) have
/// been appended since the last take, and on every append after that until a take; the writer
/// then calls ``takeBatch()`` and hands that array to the ledger, which
/// folds it off the writer's thread. The half being handed over is never overwritten before it
/// is copied, and the cost is one copy per ``batchSize`` slots. Slots the ring overwrote before
/// anyone took them are counted in ``droppedCount``.
///
/// Not `Sendable`: one thread owns it (the single writer).
public final class InputLatencyRing {
    /// The slots a ring holds unless told otherwise.
    public static let defaultCapacity = 256

    /// Slots, a power of two.
    public let capacity: Int
    /// Slots per batch: half the ring.
    public let batchSize: Int
    /// Slots appended since the ring was made.
    public private(set) var appendedCount: UInt64 = 0
    /// Slots overwritten before a take copied them.
    public private(set) var droppedCount: UInt64 = 0

    private let mask: UInt64
    private let slots: UnsafeMutablePointer<InputLatencySlot>
    /// Slots before this sequence were taken (or counted as dropped).
    private var takenThrough: UInt64 = 0

    /// A ring of at least `capacity` slots (rounded up to a power of two, at least 2).
    public init(capacity: Int = InputLatencyRing.defaultCapacity) {
        var size = 2
        while size < capacity { size <<= 1 }
        self.capacity = size
        batchSize = size / 2
        mask = UInt64(size - 1)
        slots = .allocate(capacity: size)
        slots.initialize(repeating: InputLatencySlot(kind: .keyPress, target: .other, entrypoint: .person), count: size)
    }

    deinit {
        slots.deinitialize(count: capacity)
        slots.deallocate()
    }

    /// Writes `slot` after the newest one.
    ///
    /// - Returns: True when ``batchSize`` or more slots wait for a take: call ``takeBatch()`` now.
    // perf-hot: 0.05us key-dispatch
    @discardableResult
    public func append(_ slot: InputLatencySlot) -> Bool {
        slots[Int(truncatingIfNeeded: appendedCount & mask)] = slot
        appendedCount &+= 1
        return appendedCount &- takenThrough >= UInt64(batchSize)
    }

    /// The slots appended since the last take, oldest first, now counted as taken. Slots the
    /// ring overwrote first are skipped and counted in ``droppedCount``.
    public func takeBatch() -> [InputLatencySlot] {
        let oldestKept = appendedCount > UInt64(capacity) ? appendedCount - UInt64(capacity) : 0
        let from = max(takenThrough, oldestKept)
        droppedCount &+= from - takenThrough
        let batch = (from..<appendedCount).map { slots[Int(truncatingIfNeeded: $0 & mask)] }
        takenThrough = appendedCount
        return batch
    }

    /// The newest `count` slots (at most ``capacity``), newest first. Does not take them.
    public func recent(_ count: Int) -> [InputLatencySlot] {
        let available = Int(min(appendedCount, UInt64(capacity)))
        let wanted = min(max(count, 0), available)
        return (0..<wanted).map { offset in slots[Int(truncatingIfNeeded: (appendedCount &- 1 &- UInt64(offset)) & mask)] }
    }
}
