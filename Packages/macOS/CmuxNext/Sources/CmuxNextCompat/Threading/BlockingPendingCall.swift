#if DEBUG || CMUX_BLOCKING_CHECKS
internal import Darwin

/// A new blocking call site on its way from the main thread to the drain queue: a fixed-size value
/// (no reference, no allocation) that a ``BlockingPendingRing`` slot holds.
struct BlockingPendingCall {
    /// The most return addresses kept.
    static let depth = 8

    var kind: BlockingKind
    var site: Int
    var fileID: StaticString
    var line: UInt
    // Each address in its own field: a fixed-size value, no array allocation on the main thread.
    private var addresses: (UInt, UInt, UInt, UInt, UInt, UInt, UInt, UInt) = (0, 0, 0, 0, 0, 0, 0, 0)
    private var addressCount = 0

    init(kind: BlockingKind, site: Int, fileID: StaticString, line: UInt) {
        self.kind = kind
        self.site = site
        self.fileID = fileID
        self.line = line
    }

    /// Keeps the calling thread's stack, innermost first, without this function's own frame.
    mutating func captureStack() {
        var taken = addresses
        var count = 0
        withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: Self.depth + 1) { buffer in
            guard let base = buffer.baseAddress else { return }
            let found = Int(backtrace(base, Int32(buffer.count)))
            withUnsafeMutableBytes(of: &taken) { raw in
                let slots = raw.bindMemory(to: UInt.self)
                for index in 1..<max(1, found) {
                    slots[index - 1] = UInt(bitPattern: buffer[index])
                    count = index
                }
            }
        }
        addresses = taken
        addressCount = count
    }

    /// The kept return addresses, innermost first.
    var stack: [UInt] {
        withUnsafeBytes(of: addresses) { Array($0.bindMemory(to: UInt.self).prefix(addressCount)) }
    }
}
#endif
