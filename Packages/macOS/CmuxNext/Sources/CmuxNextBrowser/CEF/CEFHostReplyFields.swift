/// The fields of one Chromium Host REPLY: an async op's result, then its out-parameters
/// (plans/cmux-next/chromium-host-ops.json, `async`). The remote shim's reply callback hands them
/// over as one EncodeFields body (`u8 type | u8 tag | u16 length | bytes`, little-endian,
/// ChromiumHost/src/chromium_host_tlv.h). Read in order, as `TlvReader` reads them there; a read of
/// the wrong type, a read past the end or a field left unread is ``CEFHostReplyError/malformed``,
/// as a bad frame is in content/browser/bad_message.cc.
nonisolated struct CEFHostReplyFields: Sendable {
    private nonisolated enum Field: Sendable {
        case i32(Int32)
        case i64(Int64)
        case f64(Double)
        /// A bytes or str field; `isNull` is the tag's NULL flag (a NULL `const char*` or buffer).
        case data([UInt8], isText: Bool, isNull: Bool)
    }

    private static let tagNull: UInt8 = 1
    private static let headerSize = 4

    private let fields: [Field]
    private var next = 0

    /// Parses an EncodeFields body.
    init(encoded body: [UInt8]) throws(CEFHostReplyError) {
        var fields: [Field] = []
        var at = 0
        while at < body.count {
            guard body.count - at >= Self.headerSize else { throw .malformed }
            let type = body[at]
            let isNull = body[at + 1] == Self.tagNull
            let length = Int(Self.littleEndian(body[(at + 2)..<(at + 4)]))
            at += Self.headerSize
            guard length <= body.count - at else { throw .malformed }
            let value = body[at..<(at + length)]
            at += length
            switch (type, length) {
            case (1, 4): fields.append(.i32(Int32(truncatingIfNeeded: Self.littleEndian(value))))
            case (2, 8): fields.append(.i64(Int64(bitPattern: Self.littleEndian(value))))
            case (3, 8): fields.append(.f64(Double(bitPattern: Self.littleEndian(value))))
            case (4, _): fields.append(.data(Array(value), isText: false, isNull: isNull))
            case (5, _): fields.append(.data(Array(value), isText: true, isNull: isNull))
            default: throw .malformed
            }
        }
        self.fields = fields
    }

    /// Every field was read.
    var isAtEnd: Bool { next == fields.count }

    mutating func int32() throws(CEFHostReplyError) -> Int32 {
        guard case .i32(let value) = try take() else { throw .malformed }
        return value
    }

    mutating func uint32() throws(CEFHostReplyError) -> UInt32 {
        UInt32(bitPattern: try int32())
    }

    mutating func int64() throws(CEFHostReplyError) -> Int64 {
        guard case .i64(let value) = try take() else { throw .malformed }
        return value
    }

    mutating func double() throws(CEFHostReplyError) -> Double {
        guard case .f64(let value) = try take() else { throw .malformed }
        return value
    }

    /// A `char*` result or argument: nil for NULL, which the header tells apart from "".
    mutating func string() throws(CEFHostReplyError) -> String? {
        guard case .data(let bytes, isText: _, isNull: let isNull) = try take() else { throw .malformed }
        if isNull { return nil }
        // A bytes field carries text that is not UTF-8 (a file name); this API returns text only.
        let text = String(decoding: bytes, as: UTF8.self)
        guard text.utf8.elementsEqual(bytes) else { throw .malformed }
        return text
    }

    /// An out buffer (`B`); empty for NULL.
    mutating func bytes() throws(CEFHostReplyError) -> [UInt8] {
        guard case .data(let bytes, isText: _, isNull: _) = try take() else { throw .malformed }
        return bytes
    }

    /// An `int*` out buffer (`A`): little-endian int32 values in one bytes field.
    mutating func int32Array() throws(CEFHostReplyError) -> [Int32] {
        guard case .data(let bytes, isText: false, isNull: _) = try take(), bytes.count.isMultiple(of: 4) else { throw .malformed }
        return stride(from: 0, to: bytes.count, by: 4).map { Int32(truncatingIfNeeded: Self.littleEndian(bytes[$0..<($0 + 4)])) }
    }

    /// A string list: an int32 count, then that many strings (NULL entries read as "").
    mutating func strings() throws(CEFHostReplyError) -> [String] {
        let count = try int32()
        guard count >= 0, Int(count) <= fields.count - next else { throw .malformed }
        var out: [String] = []
        out.reserveCapacity(Int(count))
        for _ in 0..<count { out.append(try string() ?? "") }
        return out
    }

    /// Fails unless every field was read: a reply with more fields than the op's shape is not its reply.
    func finish() throws(CEFHostReplyError) {
        guard isAtEnd else { throw .malformed }
    }

    private mutating func take() throws(CEFHostReplyError) -> Field {
        guard next < fields.count else { throw .malformed }
        defer { next += 1 }
        return fields[next]
    }

    private static func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        var value: UInt64 = 0
        for (shift, byte) in bytes.enumerated() { value |= UInt64(byte) << (8 * shift) }
        return value
    }
}

/// Why an awaited Chromium Host reply did not come (``CEFHostReplies``).
nonisolated enum CEFHostReplyError: Error, Equatable, Sendable {
    /// The REPLY's fields are not the op's reply shape.
    case malformed
    /// The host exited before it answered (task 091 fails every waiter with it, as a mojo
    /// disconnect runs each pending reply callback's default).
    case hostGone
    /// No reply within the waiter's limit; the label names the op.
    case timedOut(String, Duration)
    /// The awaiting task was cancelled.
    case cancelled
    /// A second wait on the same token took it over.
    case superseded
    /// Nothing went to a host for this answer (no host attached, or the call sent no op): none can come.
    case unsent
}

/// A reply that is one value: the op's result with no out-parameters.
nonisolated protocol CEFHostReplyValue: Sendable {
    init(reply fields: inout CEFHostReplyFields) throws(CEFHostReplyError)
}

nonisolated extension Int32: CEFHostReplyValue {
    init(reply fields: inout CEFHostReplyFields) throws(CEFHostReplyError) {
        self = try fields.int32()
    }
}

/// An `unsigned int` result (a CAContextID).
nonisolated extension UInt32: CEFHostReplyValue {
    init(reply fields: inout CEFHostReplyFields) throws(CEFHostReplyError) {
        self = try fields.uint32()
    }
}

nonisolated extension Int64: CEFHostReplyValue {
    init(reply fields: inout CEFHostReplyFields) throws(CEFHostReplyError) {
        self = try fields.int64()
    }
}

/// A `char*` result; nil for NULL.
nonisolated extension Optional: CEFHostReplyValue where Wrapped == String {
    init(reply fields: inout CEFHostReplyFields) throws(CEFHostReplyError) {
        self = try fields.string()
    }
}
