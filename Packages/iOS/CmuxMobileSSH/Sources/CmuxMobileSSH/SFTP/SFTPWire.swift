import Foundation

/// SFTP v3 wire constants (draft-ietf-secsh-filexfer-02).
enum SFTPPacketType: UInt8 {
    case initialize = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attrs = 105
}

/// An `SSH_FX_*` status code. Servers may send codes beyond the named ones,
/// so this wraps the raw wire value rather than enumerating it.
struct SFTPStatusCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: UInt32
    static let ok = SFTPStatusCode(rawValue: 0)
    static let eof = SFTPStatusCode(rawValue: 1)
    static let noSuchFile = SFTPStatusCode(rawValue: 2)
    static let permissionDenied = SFTPStatusCode(rawValue: 3)

    var description: String { String(rawValue) }
}

struct SFTPOpenFlags: OptionSet {
    let rawValue: UInt32
    static let read = SFTPOpenFlags(rawValue: 0x01)
    static let write = SFTPOpenFlags(rawValue: 0x02)
    static let create = SFTPOpenFlags(rawValue: 0x08)
    static let truncate = SFTPOpenFlags(rawValue: 0x10)
}

private struct SFTPAttributeFlags: OptionSet {
    let rawValue: UInt32
    static let size = SFTPAttributeFlags(rawValue: 0x0000_0001)
    static let uidgid = SFTPAttributeFlags(rawValue: 0x0000_0002)
    static let permissions = SFTPAttributeFlags(rawValue: 0x0000_0004)
    static let acmodtime = SFTPAttributeFlags(rawValue: 0x0000_0008)
    static let extended = SFTPAttributeFlags(rawValue: 0x8000_0000)
}

/// A decoded server reply to one request.
enum SFTPResponse: Sendable {
    case status(code: SFTPStatusCode, message: String)
    case handle(Data)
    case data(Data)
    case name([SFTPEntry])
    case attrs(SFTPAttributes)
}

/// Big-endian packet body builder. `packet(type:)` prepends the length.
struct SFTPWriter {
    private(set) var body = Data()

    mutating func byte(_ value: UInt8) { body.append(value) }

    mutating func uint32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { body.append(contentsOf: $0) }
    }

    mutating func uint64(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { body.append(contentsOf: $0) }
    }

    mutating func string(_ value: Data) {
        uint32(UInt32(value.count))
        body.append(value)
    }

    mutating func string(_ value: String) { string(Data(value.utf8)) }

    mutating func attributes(_ attributes: SFTPAttributes) {
        var flags: SFTPAttributeFlags = []
        if attributes.size != nil { flags.insert(.size) }
        if attributes.uid != nil, attributes.gid != nil { flags.insert(.uidgid) }
        if attributes.permissions != nil { flags.insert(.permissions) }
        if attributes.accessTime != nil, attributes.modificationTime != nil { flags.insert(.acmodtime) }
        uint32(flags.rawValue)
        if let size = attributes.size { uint64(size) }
        if let uid = attributes.uid, let gid = attributes.gid { uint32(uid); uint32(gid) }
        if let permissions = attributes.permissions { uint32(permissions) }
        if let atime = attributes.accessTime, let mtime = attributes.modificationTime {
            uint32(UInt32(clamping: Int64(atime.timeIntervalSince1970)))
            uint32(UInt32(clamping: Int64(mtime.timeIntervalSince1970)))
        }
    }

    /// Frames `body` as `uint32 length, byte type, body`.
    func packet(type: SFTPPacketType) -> Data {
        var framed = SFTPWriter()
        framed.uint32(UInt32(body.count + 1))
        framed.byte(type.rawValue)
        framed.body.append(body)
        return framed.body
    }
}

/// Big-endian cursor over one packet payload. Every read throws
/// ``SFTPError/unexpectedPacket(_:)`` on truncation.
struct SFTPReader {
    private let bytes: Data
    private var offset: Int

    init(_ bytes: Data) {
        self.bytes = bytes
        self.offset = bytes.startIndex
    }

    private mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, bytes.endIndex - offset >= count else {
            throw SFTPError.unexpectedPacket("truncated packet")
        }
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    mutating func byte() throws -> UInt8 { try take(1).first! }

    mutating func uint32() throws -> UInt32 {
        try take(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func uint64() throws -> UInt64 {
        try take(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func string() throws -> Data {
        Data(try take(Int(try uint32())))
    }

    mutating func utf8() throws -> String {
        String(decoding: try string(), as: UTF8.self)
    }

    mutating func attributes() throws -> SFTPAttributes {
        let flags = SFTPAttributeFlags(rawValue: try uint32())
        var result = SFTPAttributes()
        if flags.contains(.size) { result.size = try uint64() }
        if flags.contains(.uidgid) {
            result.uid = try uint32()
            result.gid = try uint32()
        }
        if flags.contains(.permissions) { result.permissions = try uint32() }
        if flags.contains(.acmodtime) {
            result.accessTime = Date(timeIntervalSince1970: TimeInterval(try uint32()))
            result.modificationTime = Date(timeIntervalSince1970: TimeInterval(try uint32()))
        }
        if flags.contains(.extended) {
            for _ in 0..<(try uint32()) {
                _ = try string()
                _ = try string()
            }
        }
        return result
    }

    /// Decodes a reply payload (everything after the request id).
    mutating func response(type: UInt8) throws -> SFTPResponse {
        switch SFTPPacketType(rawValue: type) {
        case .status:
            let code = SFTPStatusCode(rawValue: try uint32())
            // Some v3 servers omit the message and language fields.
            let message = (try? utf8()) ?? ""
            return .status(code: code, message: message)
        case .handle:
            return .handle(try string())
        case .data:
            return .data(try string())
        case .name:
            let count = try uint32()
            var entries: [SFTPEntry] = []
            entries.reserveCapacity(Int(min(count, 4096)))
            for _ in 0..<count {
                entries.append(SFTPEntry(name: try utf8(), longname: try utf8(), attributes: try attributes()))
            }
            return .name(entries)
        case .attrs:
            return .attrs(try attributes())
        default:
            throw SFTPError.unexpectedPacket("type \(type)")
        }
    }
}

/// Splits the subsystem byte stream into packets (`type` + payload).
struct SFTPFramer {
    /// Largest packet accepted from the server. OpenSSH caps at 256 KiB.
    static let maxPacketLength = 1 << 24

    private var buffer = Data()

    mutating func append(_ data: Data) { buffer.append(data) }

    /// Returns the next complete packet, or `nil` when more bytes are needed.
    mutating func next() throws -> (type: UInt8, payload: Data)? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let length = buffer[start..<(start + 4)].reduce(0) { $0 << 8 | Int($1) }
        guard length >= 1, length <= Self.maxPacketLength else {
            throw SFTPError.unexpectedPacket("bad length \(length)")
        }
        guard buffer.count >= 4 + length else { return nil }
        let type = buffer[start + 4]
        let payload = Data(buffer[(start + 5)..<(start + 4 + length)])
        // Rebase instead of removeFirst so leftover bytes do not keep a growing prefix.
        buffer = Data(buffer[(start + 4 + length)...])
        return (type, payload)
    }
}
