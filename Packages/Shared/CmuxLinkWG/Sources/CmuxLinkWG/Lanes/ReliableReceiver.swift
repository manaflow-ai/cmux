/// The receiving half of one reliable lane: reorders fragments, rebuilds
/// frames in order, and states what to acknowledge.
struct ReliableReceiver {
    private struct Fragment {
        let first: Bool
        let last: Bool
        let payload: [UInt8]
    }

    let windowFragments: UInt32
    private var nextExpected: UInt32 = 0
    private var buffered: [UInt32: Fragment] = [:]
    private var assembling: [UInt8]?

    init(windowFragments: UInt32) {
        self.windowFragments = windowFragments
    }

    /// Accepts a fragment and returns every frame it completes, in order.
    mutating func receive(seq: UInt32, first: Bool, last: Bool, payload: [UInt8]) -> [[UInt8]] {
        guard seq >= nextExpected, seq < nextExpected &+ windowFragments, buffered[seq] == nil else { return [] }
        buffered[seq] = Fragment(first: first, last: last, payload: payload)
        var frames: [[UInt8]] = []
        while let fragment = buffered.removeValue(forKey: nextExpected) {
            nextExpected += 1
            if fragment.first { assembling = [] }
            assembling?.append(contentsOf: fragment.payload)
            if fragment.last, let frame = assembling {
                frames.append(frame)
                assembling = nil
            }
        }
        return frames
    }

    var ack: (next: UInt32, sack: UInt64) {
        var sack: UInt64 = 0
        for bit in 0..<64 where buffered[nextExpected &+ 1 &+ UInt32(bit)] != nil {
            sack |= 1 << UInt64(bit)
        }
        return (nextExpected, sack)
    }
}
