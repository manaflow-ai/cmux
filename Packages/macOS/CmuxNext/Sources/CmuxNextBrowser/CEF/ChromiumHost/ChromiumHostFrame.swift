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
    var v = Values()
    var flags: UInt64 = 0
    var t0: UInt64 = 0
    var t1: UInt64 = 0
    var ch: UInt16 = 0
    var unmod: UInt16 = 0
    var seq: UInt32 = 0
    var payload: [UInt8] = []

    init(_ kind: Kind, v: Values = Values(), flags: UInt64 = 0, t0: UInt64 = 0, payload: [UInt8] = []) {
        rawKind = kind.rawValue
        self.v = v
        self.flags = flags
        self.t0 = t0
        self.payload = payload
    }

    init(rawKind: UInt32) { self.rawKind = rawKind }

    var kind: Kind? { Kind(rawValue: rawKind) }
    var text: String { String(decoding: payload, as: UTF8.self) }

    /// The header and payload as sent.
    func encoded() -> [UInt8] {
        withEncodedHeader { header in Array(header) } + payload
    }

    /// Runs `body` with the 64-byte header, encoded into a buffer on the stack: a frame goes out with no
    /// heap allocation (``ChromiumHostConnection/send(_:)``). Straight-line stores, no loop: a Debug build
    /// allocates per iteration of a `for` loop.
    func withEncodedHeader<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result { // perf-hot: 1us cef-host-input (every forwarded input event)
        var header: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0, 0, 0, 0, 0)
        return try withUnsafeMutableBytes(of: &header) { raw in
            raw.storeBytes(of: rawKind.littleEndian, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: UInt32(truncatingIfNeeded: payload.count).littleEndian, toByteOffset: 4, as: UInt32.self)
            let values = v.storage
            raw.storeBytes(of: values.0.littleEndian, toByteOffset: 8, as: Int32.self)
            raw.storeBytes(of: values.1.littleEndian, toByteOffset: 12, as: Int32.self)
            raw.storeBytes(of: values.2.littleEndian, toByteOffset: 16, as: Int32.self)
            raw.storeBytes(of: values.3.littleEndian, toByteOffset: 20, as: Int32.self)
            raw.storeBytes(of: values.4.littleEndian, toByteOffset: 24, as: Int32.self)
            raw.storeBytes(of: values.5.littleEndian, toByteOffset: 28, as: Int32.self)
            raw.storeBytes(of: flags.littleEndian, toByteOffset: 32, as: UInt64.self)
            raw.storeBytes(of: t0.littleEndian, toByteOffset: 40, as: UInt64.self)
            raw.storeBytes(of: t1.littleEndian, toByteOffset: 48, as: UInt64.self)
            raw.storeBytes(of: ch.littleEndian, toByteOffset: 56, as: UInt16.self)
            raw.storeBytes(of: unmod.littleEndian, toByteOffset: 58, as: UInt16.self)
            raw.storeBytes(of: seq.littleEndian, toByteOffset: 60, as: UInt32.self)
            return try body(UnsafeRawBufferPointer(raw))
        }
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
        frame.v = Values(Int32(bitPattern: get(8, UInt32.self)), Int32(bitPattern: get(12, UInt32.self)),
                         Int32(bitPattern: get(16, UInt32.self)), Int32(bitPattern: get(20, UInt32.self)),
                         Int32(bitPattern: get(24, UInt32.self)), Int32(bitPattern: get(28, UInt32.self)))
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

extension ChromiumHostFrame {
    /// The header's six signed fields (`v[0]` to `v[5]`; meanings by kind in `chromium_host_wire.h`), held
    /// inline: a frame is a fixed-size value, so making one allocates nothing. An index past the six is not
    /// on the wire: it reads 0 and a write to it is dropped, as the encoder always sent only six.
    nonisolated struct Values: Equatable, Sendable, ExpressibleByArrayLiteral {
        static let count = 6
        /// The six fields in wire order.
        private(set) var storage: (Int32, Int32, Int32, Int32, Int32, Int32) = (0, 0, 0, 0, 0, 0)

        init() {}

        init(_ v0: Int32, _ v1: Int32 = 0, _ v2: Int32 = 0, _ v3: Int32 = 0, _ v4: Int32 = 0, _ v5: Int32 = 0) {
            storage = (v0, v1, v2, v3, v4, v5)
        }

        /// The first six of `elements` (cold frames and tests; a hot path calls the initializer above).
        init(arrayLiteral elements: Int32...) {
            for (index, value) in elements.prefix(Self.count).enumerated() { self[index] = value }
        }

        subscript(index: Int) -> Int32 {
            get {
                switch index {
                case 0: storage.0
                case 1: storage.1
                case 2: storage.2
                case 3: storage.3
                case 4: storage.4
                case 5: storage.5
                default: 0
                }
            }
            set {
                switch index {
                case 0: storage.0 = newValue
                case 1: storage.1 = newValue
                case 2: storage.2 = newValue
                case 3: storage.3 = newValue
                case 4: storage.4 = newValue
                case 5: storage.5 = newValue
                default: break
                }
            }
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.storage == rhs.storage
        }
    }
}
