#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.

/// One message of the control channel to the Chromium host
/// (plans/cmux-next/chrome-parity/p01-process.md 3.1). The C++ side is
/// `ChromiumHost/src/chromium_host_control.h`, which lists the frame layout;
/// both sides check the same golden frame (`ChromiumHostControlChannelTests`,
/// `chromium_host_control_test.cpp`).
nonisolated struct ChromiumHostControlMessage: Equatable, Sendable {
    /// A field's value; the case is its wire type.
    enum Value: Equatable, Sendable {
        case i32(Int32)
        case i64(Int64)
        case f64(Double)
        case bytes([UInt8])
        case str(String)
    }

    struct Field: Equatable, Sendable {
        var tag: UInt8
        var value: Value
    }

    static let headerSize = 12
    static let fieldHeaderSize = 4
    /// Larger payloads go as a sealed shm descriptor (task 020).
    static let maxBody = 64 * 1024
    static let maxFds = 4
    static let fdCountMask: UInt16 = 0x0007
    static let replyFlag: UInt16 = 0x0008
    static let knownFlags: UInt16 = fdCountMask | replyFlag

    var op: UInt16
    /// The message answers ``token``.
    var isReply: Bool
    var token: UInt32
    var fields: [Field]
    /// Sent: the caller's descriptors (the channel sends duplicates and the
    /// caller keeps its own). Received: descriptors the receiver owns and closes.
    var fds: [Int32]

    init(op: UInt16, token: UInt32 = 0, isReply: Bool = false, fields: [Field] = [], fds: [Int32] = []) {
        self.op = op
        self.token = token
        self.isReply = isReply
        self.fields = fields
        self.fds = fds
    }

    /// The value of the first field with `tag`.
    subscript(tag: UInt8) -> Value? {
        fields.first { $0.tag == tag }?.value
    }

    /// The frame, or nil when it would break a bound: a body over
    /// ``maxBody``, a field over 65,535 bytes, more than ``maxFds`` descriptors.
    func encoded() -> [UInt8]? {
        guard fds.count <= Self.maxFds else { return nil }
        var body: [UInt8] = []
        for field in fields {
            switch field.value {
            case .i32(let value):
                Self.putField(&body, type: 1, tag: field.tag, length: 4)
                Self.put(&body, UInt32(bitPattern: value))
            case .i64(let value):
                Self.putField(&body, type: 2, tag: field.tag, length: 8)
                Self.put(&body, UInt64(bitPattern: value))
            case .f64(let value):
                Self.putField(&body, type: 3, tag: field.tag, length: 8)
                Self.put(&body, value.bitPattern)
            case .bytes(let bytes):
                guard bytes.count <= Int(UInt16.max) else { return nil }
                Self.putField(&body, type: 4, tag: field.tag, length: bytes.count)
                body.append(contentsOf: bytes)
            case .str(let text):
                let bytes = Array(text.utf8)
                guard bytes.count <= Int(UInt16.max) else { return nil }
                Self.putField(&body, type: 5, tag: field.tag, length: bytes.count)
                body.append(contentsOf: bytes)
            }
            guard body.count <= Self.maxBody else { return nil }
        }
        var frame: [UInt8] = []
        frame.reserveCapacity(Self.headerSize + body.count)
        Self.put(&frame, UInt32(body.count))
        Self.put(&frame, op)
        Self.put(&frame, (isReply ? Self.replyFlag : 0) | UInt16(fds.count))
        Self.put(&frame, token)
        frame.append(contentsOf: body)
        return frame
    }

    enum Decoded: Equatable, Sendable {
        /// A whole frame, and how many bytes of the input it took.
        case frame(ChromiumHostControlMessage, consumed: Int)
        /// The input ends inside a frame.
        case needMore
        /// The stream is broken: the connection ends.
        case malformed
    }

    /// Decodes the first frame of `bytes`. `fds` holds the descriptors
    /// received and not given to a frame yet, oldest first; a frame takes its
    /// count from the front. Malformed as soon as the header is bad, before
    /// its body arrives.
    static func decode(_ bytes: ArraySlice<UInt8>, fds: inout [Int32]) -> Decoded {
        guard bytes.count >= headerSize else { return .needMore }
        let base = bytes.startIndex
        func get<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
            var value: T = 0
            for index in 0..<MemoryLayout<T>.size {
                value |= T(truncatingIfNeeded: bytes[base + offset + index]) << (8 * index)
            }
            return value
        }
        let length = Int(get(0, UInt32.self))
        let flags = get(6, UInt16.self)
        let fdCount = Int(flags & fdCountMask)
        guard length <= maxBody, flags & ~knownFlags == 0, fdCount <= maxFds else { return .malformed }
        guard bytes.count >= headerSize + length else { return .needMore }
        var message = ChromiumHostControlMessage(op: get(4, UInt16.self), token: get(8, UInt32.self),
                                                 isReply: flags & replyFlag != 0)
        var at = headerSize
        let end = headerSize + length
        while at < end {
            guard end - at >= fieldHeaderSize else { return .malformed }
            let type = bytes[base + at]
            let tag = bytes[base + at + 1]
            let fieldLength = Int(get(at + 2, UInt16.self))
            at += fieldHeaderSize
            guard fieldLength <= end - at else { return .malformed }
            let value: Value
            switch (type, fieldLength) {
            case (1, 4): value = .i32(Int32(bitPattern: get(at, UInt32.self)))
            case (2, 8): value = .i64(Int64(bitPattern: get(at, UInt64.self)))
            case (3, 8): value = .f64(Double(bitPattern: get(at, UInt64.self)))
            case (4, _): value = .bytes(Array(bytes[(base + at)..<(base + at + fieldLength)]))
            case (5, _):
                let raw = bytes[(base + at)..<(base + at + fieldLength)]
                let text = String(decoding: raw, as: UTF8.self)
                // Invalid UTF-8 decodes to U+FFFD, which does not encode back to the same bytes.
                guard text.utf8.elementsEqual(raw) else { return .malformed }
                value = .str(text)
            default: return .malformed
            }
            at += fieldLength
            message.fields.append(Field(tag: tag, value: value))
        }
        guard fds.count >= fdCount else { return .malformed }
        message.fds = Array(fds.prefix(fdCount))
        fds.removeFirst(fdCount)
        return .frame(message, consumed: end)
    }

    private static func putField(_ out: inout [UInt8], type: UInt8, tag: UInt8, length: Int) {
        out.append(type)
        out.append(tag)
        put(&out, UInt16(length))
    }

    private static func put<T: FixedWidthInteger>(_ out: inout [UInt8], _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
    }
}
#endif
