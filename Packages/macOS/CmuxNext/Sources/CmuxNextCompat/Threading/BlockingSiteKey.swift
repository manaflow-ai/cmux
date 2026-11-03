#if DEBUG || CMUX_BLOCKING_CHECKS
/// What identifies one blocking call site: the address of the caller's `#fileID` string (one per file in
/// the binary) and its `#line`. Seams and ``Mutex/withLock(fileID:line:_:)`` pass both.
struct BlockingSiteKey: Equatable {
    let first: UInt
    let second: UInt

    /// The site of a seam call.
    init(fileID: StaticString, line: UInt) {
        first = fileID.hasPointerRepresentation ? UInt(bitPattern: fileID.utf8Start) : UInt(fileID.unicodeScalar.value)
        second = line &+ 1  // never 0, so a key is never the empty slot
    }

    /// The empty slot of ``BlockingSiteIndex``.
    static let empty = BlockingSiteKey(raw: 0, 0)

    private init(raw first: UInt, _ second: UInt) {
        self.first = first
        self.second = second
    }

    var hash: Int {
        var mixed = first &* 0x9E37_79B9_7F4A_7C15 ^ second &* 0xC2B2_AE3D_27D4_EB4F
        mixed ^= mixed >> 29
        return Int(truncatingIfNeeded: mixed)
    }
}
#endif
