#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat

/// A fixed multi-producer, single-consumer ring of ``HopRecord``s: any thread that enqueues a
/// main-actor job and the main run loop's callout timer push, the fold pops. Dmitry Vyukov's
/// bounded queue: a producer claims a slot by moving the enqueue cursor, writes the slot's words,
/// then publishes it with its sequence word. Lock-free and allocation-free after its init; a full
/// ring refuses the record and the producer counts it.
final class HopRing: Sendable {
    let capacity: Int
    private let slots: [Slot]
    private let enqueueCursor = Atomic<UInt64>(0)
    private let dequeueCursor = Atomic<UInt64>(0)

    /// One slot's words. The payload is relaxed: the release store of `sequence` publishes it to
    /// the consumer's acquire load, and the consumer's release store of `sequence` frees it.
    private final class Slot: Sendable {
        let sequence: Atomic<UInt64>
        let meta = Atomic<UInt64>(0)
        let nanos = Atomic<UInt64>(0)
        let site = Atomic<UInt>(0)
        let addresses: [HopWord] = (0..<HopRecord.depth).map { _ in HopWord() }

        init(_ index: Int) {
            sequence = Atomic(UInt64(index))
        }
    }

    /// - Parameter capacity: Slots (at least 2, rounded up to a power of two).
    init(capacity: Int) {
        var count = 2
        while count < capacity { count <<= 1 }
        self.capacity = count
        slots = (0..<count).map { Slot($0) }
    }

    /// Records written and not popped yet.
    var count: Int {
        Int(clamping: enqueueCursor.load(ordering: .acquiring) &- dequeueCursor.load(ordering: .acquiring))
    }

    /// Adds `record` (any thread; no allocation, lock or system call); false when the ring is full.
    func push(_ record: HopRecord) -> Bool {
        var position = enqueueCursor.load(ordering: .relaxed)
        while true {
            let slot = slots[Int(position & UInt64(capacity - 1))]
            let sequence = slot.sequence.load(ordering: .acquiring)
            if sequence == position {
                let claim = enqueueCursor.weakCompareExchange(expected: position, desired: position + 1, ordering: .relaxed)
                guard claim.exchanged else {
                    position = claim.original
                    continue
                }
                slot.meta.store(record.meta, ordering: .relaxed)
                slot.nanos.store(record.nanos, ordering: .relaxed)
                slot.site.store(record.site, ordering: .relaxed)
                withUnsafeBytes(of: record.addresses) { raw in
                    let addresses = raw.bindMemory(to: UInt.self)
                    for index in 0..<record.addressCount {
                        slot.addresses[index].value.store(addresses[index], ordering: .relaxed)
                    }
                }
                slot.sequence.store(position + 1, ordering: .releasing)
                return true
            } else if sequence < position {
                return false
            } else {
                position = enqueueCursor.load(ordering: .relaxed)
            }
        }
    }

    /// Takes the oldest published record (one consumer at a time: the recorder's fold lock); nil
    /// when none is published.
    func pop() -> HopRecord? {
        let position = dequeueCursor.load(ordering: .relaxed)
        let slot = slots[Int(position & UInt64(capacity - 1))]
        guard slot.sequence.load(ordering: .acquiring) == position + 1 else { return nil }
        let meta = slot.meta.load(ordering: .relaxed)
        let nanos = slot.nanos.load(ordering: .relaxed)
        let site = slot.site.load(ordering: .relaxed)
        let depth = min(HopRecord.depth, Int(UInt8(truncatingIfNeeded: meta >> 40)))
        let stack = (0..<depth).map { slot.addresses[$0].value.load(ordering: .relaxed) }
        slot.sequence.store(position + UInt64(capacity), ordering: .releasing)
        dequeueCursor.store(position + 1, ordering: .releasing)
        return HopRecord(meta: meta, nanos: nanos, site: site, stack: stack)
    }
}
#endif
