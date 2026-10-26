#if DEBUG || CMUX_BLOCKING_CHECKS
internal import Darwin

/// A new blocking call site on its way from the main thread to the drain queue: a fixed-size value
/// (no reference, no allocation) that a ``BlockingPendingRing`` slot holds.
struct BlockingPendingCall {
    /// The most return addresses kept.
    static let depth = 8

    var kind: BlockingKind
    /// What the seam itself waits on: ``kind``, except at a ``BlockingKind/wrongLane`` site.
    var seamKind: BlockingKind
    var site: Int
    var fileID: StaticString
    var line: UInt
    // Each address in its own field: a fixed-size value, no array allocation on the main thread.
    private var addresses: (UInt, UInt, UInt, UInt, UInt, UInt, UInt, UInt) = (0, 0, 0, 0, 0, 0, 0, 0)
    private var addressCount = 0

    init(kind: BlockingKind, seamKind: BlockingKind? = nil, site: Int, fileID: StaticString, line: UInt) {
        self.kind = kind
        self.seamKind = seamKind ?? kind
        self.site = site
        self.fileID = fileID
        self.line = line
    }

    /// Keeps the calling thread's stack, innermost first, without this function's own frame.
    mutating func captureStack() {
        var count = 0
        // SAFETY: a scratch buffer of depth + 1 frames that lives only for the closure; backtrace writes at most
        // buffer.count of them and returns how many, and only indices under that count (clamped to the buffer) are
        // read. The addresses are copied out as integers, never dereferenced.
        unsafe withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: Self.depth + 1) { buffer in
            guard let base = unsafe buffer.baseAddress else { return }
            let found = unsafe min(Int(backtrace(base, Int32(buffer.count))), buffer.count)
            for index in 1..<max(1, found) {
                set(index - 1, unsafe UInt(bitPattern: buffer[index]))
                count = index
            }
        }
        addressCount = count
    }

    /// The kept return addresses, innermost first.
    var stack: [UInt] {
        (0..<addressCount).map(address)
    }

    /// Stores return address `index` (under ``depth``) in its field.
    private mutating func set(_ index: Int, _ address: UInt) {
        switch index {
        case 0: addresses.0 = address
        case 1: addresses.1 = address
        case 2: addresses.2 = address
        case 3: addresses.3 = address
        case 4: addresses.4 = address
        case 5: addresses.5 = address
        case 6: addresses.6 = address
        case 7: addresses.7 = address
        default: break
        }
    }

    /// Return address `index` (under ``depth``).
    private func address(_ index: Int) -> UInt {
        switch index {
        case 0: addresses.0
        case 1: addresses.1
        case 2: addresses.2
        case 3: addresses.3
        case 4: addresses.4
        case 5: addresses.5
        case 6: addresses.6
        case 7: addresses.7
        default: 0
        }
    }
}
#endif
