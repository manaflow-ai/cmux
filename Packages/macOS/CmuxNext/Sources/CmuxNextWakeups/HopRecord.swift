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
#endif
