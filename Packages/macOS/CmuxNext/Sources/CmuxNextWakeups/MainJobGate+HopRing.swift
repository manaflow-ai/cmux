#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
import Darwin

/// One hop as a producer writes it: a main-actor job enqueued during an input turn (with its stack)
/// or a timed non-Swift callout of the main run loop. A fixed-size value: no reference, no
/// allocation on the recording thread.
struct HopRecord {
    /// The most return addresses kept.
    static let depth = 8

    var lane: MainJobGateDiagnostics.Lane
    /// ``MainJobGateDiagnostics/Origin`` (Swift) or ``MainJobGateDiagnostics/RunLoopModeName`` (non-Swift).
    var origin: UInt8
    var priority: UInt8 = 0
    var turn: MainJobGateDiagnostics.InputTurn
    var callout: MainJobGateDiagnostics.CalloutKind = .sources
    var nanos: UInt64 = 0
    // Each address in its own field: a fixed-size value, no array allocation on the recording thread.
    var addresses: (UInt, UInt, UInt, UInt, UInt, UInt, UInt, UInt) = (0, 0, 0, 0, 0, 0, 0, 0)
    var addressCount = 0

    /// Keeps the calling thread's stack, innermost first, without this function's frame and
    /// `skipping` frames of its callers (the recorder's own entry point).
    @inline(never)
    mutating func captureStack(skipping: Int) {
        var taken = addresses
        var count = 0
        let skipped = 1 + skipping
        withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: Self.depth + skipped) { buffer in
            guard let base = buffer.baseAddress else { return }
            let found = Int(backtrace(base, Int32(buffer.count)))
            guard found > skipped else { return }
            withUnsafeMutableBytes(of: &taken) { raw in
                let slots = raw.bindMemory(to: UInt.self)
                for index in skipped..<found {
                    slots[index - skipped] = UInt(bitPattern: buffer[index])
                    count = index - skipped + 1
                }
            }
        }
        addresses = taken
        addressCount = count
    }

    /// Sets the stack from `stack` (tests, and the ring's read), innermost first; past ``depth`` is cut.
    mutating func setStack(_ stack: some Collection<UInt>) {
        var taken: (UInt, UInt, UInt, UInt, UInt, UInt, UInt, UInt) = (0, 0, 0, 0, 0, 0, 0, 0)
        var count = 0
        withUnsafeMutableBytes(of: &taken) { raw in
            let slots = raw.bindMemory(to: UInt.self)
            for address in stack.prefix(Self.depth) {
                slots[count] = address
                count += 1
            }
        }
        addresses = taken
        addressCount = count
    }

    /// The kept return addresses, innermost first.
    var stack: [UInt] {
        withUnsafeBytes(of: addresses) { Array($0.bindMemory(to: UInt.self).prefix(addressCount)) }
    }

    /// The fields other than the stack and the time, in one word.
    var meta: UInt64 {
        UInt64(lane.rawValue) | UInt64(origin) << 8 | UInt64(priority) << 16 | UInt64(turn.rawValue) << 24
            | UInt64(callout.rawValue) << 32 | UInt64(addressCount) << 40
    }

    init(lane: MainJobGateDiagnostics.Lane, origin: UInt8, priority: UInt8 = 0, turn: MainJobGateDiagnostics.InputTurn,
         callout: MainJobGateDiagnostics.CalloutKind = .sources, nanos: UInt64 = 0) {
        self.lane = lane
        self.origin = origin
        self.priority = priority
        self.turn = turn
        self.callout = callout
        self.nanos = nanos
    }

    init(meta: UInt64, nanos: UInt64, stack: [UInt]) {
        self.init(lane: MainJobGateDiagnostics.Lane(rawValue: UInt8(truncatingIfNeeded: meta)) ?? .nonswift,
                  origin: UInt8(truncatingIfNeeded: meta >> 8), priority: UInt8(truncatingIfNeeded: meta >> 16),
                  turn: MainJobGateDiagnostics.InputTurn(rawValue: UInt8(truncatingIfNeeded: meta >> 24)),
                  callout: MainJobGateDiagnostics.CalloutKind(rawValue: UInt8(truncatingIfNeeded: meta >> 32)) ?? .sources,
                  nanos: nanos)
        setStack(stack.prefix(Int(UInt8(truncatingIfNeeded: meta >> 40))))
    }
}

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
        let addresses: [Word] = (0..<HopRecord.depth).map { _ in Word() }

        init(_ index: Int) {
            sequence = Atomic(UInt64(index))
        }
    }

    /// One return address of a slot (an `Atomic` cannot be an array element).
    private final class Word: Sendable {
        let value = Atomic<UInt>(0)
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
        let depth = min(HopRecord.depth, Int(UInt8(truncatingIfNeeded: meta >> 40)))
        let stack = (0..<depth).map { slot.addresses[$0].value.load(ordering: .relaxed) }
        slot.sequence.store(position + UInt64(capacity), ordering: .releasing)
        dequeueCursor.store(position + 1, ordering: .releasing)
        return HopRecord(meta: meta, nanos: nanos, stack: stack)
    }
}
#endif
