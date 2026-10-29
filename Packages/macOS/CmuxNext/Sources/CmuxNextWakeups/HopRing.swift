#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
import Darwin

/// One hop as a producer writes it: a main-actor job enqueued during an input turn (with its stack)
/// or a timed non-Swift callout of the main run loop. A fixed-size value: no reference, no
/// allocation on the recording thread.
struct HopRecord {
    /// The most return addresses kept. The capture keeps the recorder's and the hook's own frames
    /// and the runtime frames of the enqueue before the site (``HopFrameResolver/siteIndex(_:)``
    /// skips them), so the stack has room for all of them and a few frames past the site.
    static let depth = 16
    typealias Addresses = (UInt, UInt, UInt, UInt, UInt, UInt, UInt, UInt, UInt, UInt, UInt, UInt, UInt, UInt, UInt, UInt)
    /// Computed, not a stored static: the recording thread never runs a lazy global initializer.
    static var noAddresses: Addresses { (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }

    var lane: InputTurnHopRecorder.Lane
    /// ``InputTurnHopRecorder/Origin`` (Swift) or ``InputTurnHopRecorder/RunLoopModeName`` (non-Swift).
    var origin: UInt8
    var priority: UInt8 = 0
    var turn: InputTurnHopRecorder.InputTurn
    var callout: InputTurnHopRecorder.CalloutKind = .sources
    var nanos: UInt64 = 0
    /// A sampled non-Swift callout: the return address of its site (``CalloutStackSampler``); 0 when
    /// the callout was not sampled or its site was not found.
    var site: UInt = 0
    /// A sampled non-Swift callout that ran a Swift job (the swift lane names that job's enqueue too).
    var swiftJob = false
    // Each address in its own field: a fixed-size value, no array allocation on the recording thread.
    var addresses: Addresses = HopRecord.noAddresses
    var addressCount = 0

    /// Keeps the calling thread's stack, innermost first, from this function's own frame: the
    /// recorder's, the hook's and the runtime's frames come first and the fold skips them by image
    /// (``HopFrameResolver/siteIndex(_:)``), so no frame count depends on what the optimizer
    /// inlined. `backtrace_async` follows a running task's async frames past the synchronous ones:
    /// a hop enqueued by an `await` (`swift_task_switch`, reached by a tail call that leaves no
    /// frame of the awaiting function) resumes in the awaiting function, which is its site.
    @inline(never)
    mutating func captureStack() {
        var taken = Self.noAddresses
        var count = 0
        withUnsafeMutableBytes(of: &taken) { raw in
            let slots = raw.bindMemory(to: UnsafeMutableRawPointer?.self)
            guard let base = slots.baseAddress else { return }
            var task: UInt32 = 0
            count = min(Self.depth, backtrace_async(base, slots.count, &task))
        }
        addresses = taken
        addressCount = count
    }

    /// Sets the stack from `stack` (tests, the ring's read and the sampler), innermost first; past
    /// ``depth`` is cut.
    mutating func setStack(_ stack: some Collection<UInt>) {
        var taken = Self.noAddresses
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

    /// The fields other than the stack, the site and the time, in one word.
    var meta: UInt64 {
        UInt64(lane.rawValue) | UInt64(origin) << 8 | UInt64(priority) << 16 | UInt64(turn.rawValue) << 24
            | UInt64(callout.rawValue) << 32 | UInt64(addressCount) << 40 | (swiftJob ? UInt64(1) << 48 : 0)
    }

    init(lane: InputTurnHopRecorder.Lane, origin: UInt8, priority: UInt8 = 0, turn: InputTurnHopRecorder.InputTurn,
         callout: InputTurnHopRecorder.CalloutKind = .sources, nanos: UInt64 = 0) {
        self.lane = lane
        self.origin = origin
        self.priority = priority
        self.turn = turn
        self.callout = callout
        self.nanos = nanos
    }

    init(meta: UInt64, nanos: UInt64, site: UInt, stack: [UInt]) {
        self.init(lane: InputTurnHopRecorder.Lane(rawValue: UInt8(truncatingIfNeeded: meta)) ?? .nonswift,
                  origin: UInt8(truncatingIfNeeded: meta >> 8), priority: UInt8(truncatingIfNeeded: meta >> 16),
                  turn: InputTurnHopRecorder.InputTurn(rawValue: UInt8(truncatingIfNeeded: meta >> 24)),
                  callout: InputTurnHopRecorder.CalloutKind(rawValue: UInt8(truncatingIfNeeded: meta >> 32)) ?? .sources,
                  nanos: nanos)
        self.site = site
        swiftJob = meta & (1 << 48) != 0
        setStack(stack.prefix(Int(UInt8(truncatingIfNeeded: meta >> 40))))
    }
}

/// One atomic word of a fixed table (an `Atomic` cannot be an array element): a ring slot's
/// return address, a callout sample's.
final class HopWord: Sendable {
    let value = Atomic<UInt>(0)
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
