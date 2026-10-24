/// One frame of the wire between cmux and the Chromium host app (prototype
/// behind `browserHost.helperPrototype`; plans/cmux-next/cef-helper-app-DESIGN.md).
///
/// The C++ side is `CEFShim/src/chromium_host_wire.h`: a 64-byte
/// little-endian header and `payload` bytes after it. Both sides check the
/// same golden frame (`ChromiumHostFrameTests`, `chromium_host_wire_test.cpp`).
/// Field meanings by kind are listed in the header.
nonisolated struct ChromiumHostFrame: Equatable, Sendable {
    enum Kind: UInt32, Sendable {
        // cmux -> host
        case navigate = 1, geometry = 2, mouse = 3, wheel = 4, key = 5, focus = 6, ping = 7, stats = 8, quit = 9, edit = 10
        // host -> cmux
        case ready = 101, context = 102, address = 103, title = 104, pong = 105, statsReply = 106, error = 107
        case rendererGone = 108
    }

    static let headerSize = 64
    /// Longer payloads end the connection: no kind carries more than a URL.
    static let maxPayload = 64 * 1024

    /// The raw kind, so a frame of a kind this side does not know still decodes.
    var rawKind: UInt32
    var v: [Int32] = [0, 0, 0, 0, 0, 0]
    var flags: UInt64 = 0
    var t0: UInt64 = 0
    var t1: UInt64 = 0
    var ch: UInt16 = 0
    var unmod: UInt16 = 0
    var seq: UInt32 = 0
    var payload: [UInt8] = []

    init(_ kind: Kind, v: [Int32] = [], flags: UInt64 = 0, t0: UInt64 = 0, payload: [UInt8] = []) {
        rawKind = kind.rawValue
        for (index, value) in v.prefix(6).enumerated() { self.v[index] = value }
        self.flags = flags
        self.t0 = t0
        self.payload = payload
    }

    init(rawKind: UInt32) { self.rawKind = rawKind }

    var kind: Kind? { Kind(rawValue: rawKind) }
    var text: String { String(decoding: payload, as: UTF8.self) }

    /// The header and payload as sent.
    func encoded() -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(Self.headerSize + payload.count)
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        put(rawKind)
        put(UInt32(payload.count))
        for value in v { put(UInt32(bitPattern: value)) }
        put(flags)
        put(t0)
        put(t1)
        put(ch)
        put(unmod)
        put(seq)
        bytes.append(contentsOf: payload)
        return bytes
    }

    enum Decoded: Equatable, Sendable {
        /// A whole frame, and how many bytes of the input it took.
        case frame(ChromiumHostFrame, consumed: Int)
        /// The input ends inside a frame.
        case needMore
        /// The header announces a payload over ``maxPayload``: the stream is broken.
        case invalid
    }

    /// Decodes the first frame of `bytes`.
    static func decode(_ bytes: ArraySlice<UInt8>) -> Decoded {
        guard bytes.count >= headerSize else { return .needMore }
        let base = bytes.startIndex
        func get<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
            var value: T = 0
            for index in 0..<MemoryLayout<T>.size {
                value |= T(bytes[base + offset + index]) << (8 * index)
            }
            return value
        }
        let length = Int(get(4, UInt32.self))
        guard length <= maxPayload else { return .invalid }
        guard bytes.count >= headerSize + length else { return .needMore }
        var frame = ChromiumHostFrame(rawKind: get(0, UInt32.self))
        frame.v = (0..<6).map { Int32(bitPattern: get(8 + 4 * $0, UInt32.self)) }
        frame.flags = get(32, UInt64.self)
        frame.t0 = get(40, UInt64.self)
        frame.t1 = get(48, UInt64.self)
        frame.ch = get(56, UInt16.self)
        frame.unmod = get(58, UInt16.self)
        frame.seq = get(60, UInt32.self)
        frame.payload = Array(bytes[(base + headerSize)..<(base + headerSize + length)])
        return .frame(frame, consumed: headerSize + length)
    }
}
