// STAND-IN for p05-ipc-054 (Swift FrameReader with pooled buffers and small-copy rule). The round-3
// compile fixer of perf/chrome-parity wrote it so that p05-ipc-057's FrameFuzzTests compiles before 054
// lands. It is the interface that the 054 paragraph of plans/cmux-next/chrome-parity/p05-ipc.md pins,
// over a plain byte array: a line-for-line port of cmux-tui/crates/cmux-ipc/src/reader.rs and frame.rs,
// with the same check order and reason strings. It has no recvmsg path, no pooled
// refcounted buffers, no no-copy slices for large OUTPUT/SNAPSHOT/REPLAY payloads and no fd FIFO.
// p05-ipc-054 must replace this whole file (its FrameHeader.swift, FrameReader.swift and ReadBuffer.swift)
// and keep the interface, or change FrameFuzzTests with it.

/// Why the reader refused the stream: the Rust `BadMessage` of cmux-ipc frame.rs. The first bad message is
/// the answer of every later ``FrameReader/next()`` call.
public enum BadMessage: Error, Sendable, Equatable {
    case badMagic(found: UInt8)
    case unknownKind(UInt8)
    case oversize(length: UInt32, max: UInt32)
    case dataOnControlStream(kind: UInt8)
    case unknownPriority(UInt8)
    case unknownFlags(UInt8)
    case framesNotNegotiated
    case lineTooLong(max: Int)
    case invalidUTF8(validUpTo: Int)
    case truncated(have: Int, need: Int)

    /// The Rust `BadMessage::reason()` string.
    public var reason: String {
        switch self {
        case .badMagic: "bad_magic"
        case .unknownKind: "unknown_kind"
        case .oversize: "oversize"
        case .dataOnControlStream: "data_on_control_stream"
        case .unknownPriority: "unknown_priority"
        case .unknownFlags: "unknown_flags"
        case .framesNotNegotiated: "frames_not_negotiated"
        case .lineTooLong: "line_too_long"
        case .invalidUTF8: "invalid_utf8"
        case .truncated: "truncated"
        }
    }
}

/// A validated 16-byte frame header (p05-ipc.md section 3.2): magic 0xFF, kind, stream (LE u16), payload
/// length (LE u32), then 8 aux bytes.
public struct FrameHeader: Sendable, Equatable {
    /// Bytes in a header on the wire.
    public static let byteCount = 16
    /// The first byte of every frame.
    public static let magic: UInt8 = 0xFF
    /// The largest payload any frame may carry (32 MiB), whatever the reader's own limit.
    public static let maxPayloadCap: UInt32 = 32 * 1024 * 1024

    private let bytes: [UInt8]

    /// The wire kind byte.
    public var kind: UInt8 { bytes[1] }
    /// The stream id; 0 is the control stream.
    public var stream: UInt16 { UInt16(bytes[2]) | UInt16(bytes[3]) << 8 }
    /// The payload length in bytes.
    public var length: UInt32 { Self.littleEndian32(bytes, at: 4) }

    /// Decodes and checks a header in the order of frame.rs `FrameHeader::decode`.
    init(decoding wire: ArraySlice<UInt8>, maxPayload: UInt32) throws(BadMessage) {
        let raw = Array(wire)
        guard raw.count == Self.byteCount else { throw .truncated(have: raw.count, need: Self.byteCount) }
        guard raw[0] == Self.magic else { throw .badMagic(found: raw[0]) }
        let kind = raw[1]
        guard Self.isKnownKind(kind) else { throw .unknownKind(kind) }
        let length = Self.littleEndian32(raw, at: 4)
        let cap = min(maxPayload, Self.maxPayloadCap)
        guard length <= cap else { throw .oversize(length: length, max: cap) }
        let isCall = Self.isCallKind(kind)
        if isCall {
            guard raw[14] <= 3 else { throw .unknownPriority(raw[14]) }
            guard raw[15] & 0xE0 == 0 else { throw .unknownFlags(raw[15]) }
        }
        let stream = UInt16(raw[2]) | UInt16(raw[3]) << 8
        if stream == 0, !isCall, kind != Self.sharedBufferKind { throw .dataOnControlStream(kind: kind) }
        bytes = raw
    }

    /// The 16 wire bytes.
    public func encode() -> [UInt8] { bytes }

    private static let sharedBufferKind: UInt8 = 10

    private static func isKnownKind(_ kind: UInt8) -> Bool {
        (1 ... 11).contains(kind) || isCallKind(kind)
    }

    private static func isCallKind(_ kind: UInt8) -> Bool {
        (16 ... 20).contains(kind)
    }

    private static func littleEndian32(_ raw: [UInt8], at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in (offset ..< offset + 4).reversed() {
            value = value << 8 | UInt32(raw[index])
        }
        return value
    }
}

/// A whole frame: its header and an owned payload of exactly ``FrameHeader/length`` bytes.
public struct Frame: Sendable, Equatable {
    public let header: FrameHeader
    public let payload: [UInt8]
}

/// Cuts a byte stream into JSON lines and 0xFF frames, as cmux-ipc reader.rs does.
public struct FrameReader: Sendable {
    /// The reader's caps: JSON line bytes (without the `\n`) and frame payload bytes. 0 is accepted.
    public struct Limits: Sendable, Equatable {
        public var maxLine: Int
        public var maxFramePayload: UInt32

        public init(maxLine: Int = 16 * 1024 * 1024, maxFramePayload: UInt32 = FrameHeader.maxPayloadCap) {
            self.maxLine = maxLine
            self.maxFramePayload = maxFramePayload
        }
    }

    /// One message: a JSON line without its `\n` (owned, valid strict UTF-8), or a frame.
    public enum Message: Sendable, Equatable {
        case json([UInt8])
        case frame(Frame)
    }

    private let limits: Limits
    private var buffer: [UInt8] = []
    /// The first unread byte of `buffer`.
    private var start = 0
    /// Bytes past `start` already searched for `\n`.
    private var scanned = 0
    private var header: FrameHeader?
    private var failed: BadMessage?
    private var framesNegotiated = false
    private var endOfStream = false

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Frames (0xFF boundaries) are allowed from now on.
    public mutating func negotiateFrames() {
        framesNegotiated = true
    }

    /// Appends bytes received elsewhere; allowed at any time.
    public mutating func push(_ bytes: UnsafeRawBufferPointer) {
        if start > 0, start >= buffer.count - start {
            buffer.removeSubrange(0 ..< start)
            start = 0
        }
        buffer.append(contentsOf: bytes)
    }

    /// No more bytes come: a partial frame is `truncated`, an unterminated line is a message.
    public mutating func markEndOfStream() {
        endOfStream = true
    }

    /// The next whole message; nil when more bytes are needed or the stream ended cleanly.
    public mutating func next() throws(BadMessage) -> Message? {
        if let failed { throw failed }
        do {
            return try cut()
        } catch {
            failed = error
            throw error
        }
    }

    private mutating func cut() throws(BadMessage) -> Message? {
        guard start < buffer.count else { return nil }
        if buffer[start] == FrameHeader.magic { return try cutFrame() }
        return try cutLine()
    }

    private mutating func cutFrame() throws(BadMessage) -> Message? {
        guard framesNegotiated else { throw .framesNotNegotiated }
        let available = buffer.count - start
        let header: FrameHeader
        if let decoded = self.header {
            header = decoded
        } else {
            guard available >= FrameHeader.byteCount else { return try pending(need: FrameHeader.byteCount) }
            header = try FrameHeader(decoding: buffer[start ..< start + FrameHeader.byteCount],
                                     maxPayload: limits.maxFramePayload)
            self.header = header
        }
        let frameLength = FrameHeader.byteCount + Int(header.length)
        guard available >= frameLength else { return try pending(need: frameLength) }
        let payload = Array(buffer[start + FrameHeader.byteCount ..< start + frameLength])
        start += frameLength
        self.header = nil
        return .frame(Frame(header: header, payload: payload))
    }

    private func pending(need: Int) throws(BadMessage) -> Message? {
        if endOfStream { throw .truncated(have: buffer.count - start, need: need) }
        return nil
    }

    private mutating func cutLine() throws(BadMessage) -> Message? {
        let max = limits.maxLine
        if let newline = buffer[(start + scanned)...].firstIndex(of: 0x0A) {
            scanned = 0
            guard newline - start <= max else { throw .lineTooLong(max: max) }
            let line = Array(buffer[start ..< newline])
            start = newline + 1
            try Self.validateUTF8(line)
            return .json(line)
        }
        let length = buffer.count - start
        guard length <= max else { throw .lineTooLong(max: max) }
        guard endOfStream else {
            scanned = length
            return nil
        }
        scanned = 0
        let line = Array(buffer[start...])
        start = buffer.count
        try Self.validateUTF8(line)
        return .json(line)
    }

    /// Strict UTF-8, as Rust `std::str::from_utf8` checks it.
    private static func validateUTF8(_ line: [UInt8]) throws(BadMessage) {
        var decoder = Unicode.UTF8()
        var iterator = line.makeIterator()
        var validUpTo = 0
        var result = decoder.decode(&iterator)
        // Ends: each step consumes at least one byte of the finite line.
        while case let .scalarValue(scalar) = result {
            validUpTo += Unicode.UTF8.width(scalar)
            result = decoder.decode(&iterator)
        }
        if case .error = result { throw .invalidUTF8(validUpTo: validUpTo) }
    }
}
