import Foundation

/// The 16-byte little-endian header of a binary attach frame:
/// `0xFF | kind u8 | stream u16 | len u32 | offset u64`. `0xFF` never starts a
/// UTF-8 JSON line, so frames and JSON lines share one byte stream.
struct AttachFrameHeader: Sendable, Equatable {
    static let size = 16
    static let magic: UInt8 = 0xFF
    /// The daemon's largest message (its `REMOTE_SESSION_MESSAGE_MAX_BYTES`).
    static let maxPayload = 32 << 20

    var kind: AttachFrameKind
    /// The client stream, 1-65535.
    var stream: UInt16
    var length: Int
    var offset: UInt64

    enum DecodeError: Error, Equatable, CustomStringConvertible {
        case short
        case magic(UInt8)
        case kind(UInt8)
        case stream
        case tooLarge(UInt64)

        var description: String {
            switch self {
            case .short: "frame header shorter than \(AttachFrameHeader.size) bytes"
            case .magic(let byte): "frame magic \(byte)"
            case .kind(let kind): "unknown frame kind \(kind)"
            case .stream: "frame without a stream"
            case .tooLarge(let length): "frame payload of \(length) bytes"
            }
        }
    }

    /// Decodes the header in the first ``size`` bytes of `bytes`.
    init(_ bytes: some Collection<UInt8>) throws(DecodeError) {
        let header = Array(bytes.prefix(Self.size))
        guard header.count == Self.size, let magic = header.first,
              let kindByte = header[checked: 1],
              let stream = Self.littleEndian(header, from: 2, count: 2),
              let length = Self.littleEndian(header, from: 4, count: 4),
              let offset = Self.littleEndian(header, from: 8, count: 8)
        else { throw .short }
        guard magic == Self.magic else { throw .magic(magic) }
        guard let kind = AttachFrameKind(rawValue: kindByte) else { throw .kind(kindByte) }
        guard stream != 0 else { throw .stream }
        guard let count = Int(exactly: length), count <= Self.maxPayload else { throw .tooLarge(length) }
        self.init(kind: kind, stream: UInt16(truncatingIfNeeded: stream), length: count, offset: offset)
    }

    /// The little-endian integer in `bytes[start ..< start + count]`; nil when
    /// the bytes are not all there.
    static func littleEndian(_ bytes: [UInt8], from start: Int, count: Int) -> UInt64? {
        var value: UInt64 = 0
        for index in 0..<count {
            guard let byte = bytes[checked: start + index] else { return nil }
            value |= UInt64(truncatingIfNeeded: byte) << (8 * UInt64(truncatingIfNeeded: index))
        }
        return value
    }

    init(kind: AttachFrameKind, stream: UInt16, length: Int, offset: UInt64) {
        self.kind = kind
        self.stream = stream
        self.length = length
        self.offset = offset
    }

    /// The header's wire bytes (tests and fakes encode frames with it).
    var encoded: Data {
        var bytes = Data([Self.magic, kind.rawValue])
        Self.appendLittleEndian(UInt64(truncatingIfNeeded: stream), count: 2, to: &bytes)
        Self.appendLittleEndian(UInt64(truncatingIfNeeded: length), count: 4, to: &bytes)
        Self.appendLittleEndian(offset, count: 8, to: &bytes)
        return bytes
    }

    private static func appendLittleEndian(_ value: UInt64, count: Int, to bytes: inout Data) {
        for index in 0..<count {
            bytes.append(UInt8(truncatingIfNeeded: value >> (8 * UInt64(truncatingIfNeeded: index))))
        }
    }
}
