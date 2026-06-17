import Foundation

/// An ordered, demand-driven source of bytes from an RFB server.
///
/// RFB runs over a TCP stream, so a single logical message can arrive split
/// across several reads. Rather than juggle a cursor over a growing buffer,
/// decoders pull exactly the bytes they need and the source blocks until they
/// are available. The real implementation is backed by `NWConnection`; tests
/// back it with an in-memory array.
public protocol RFBByteSource: Sendable {
    /// Returns exactly `count` bytes, awaiting more from the stream as needed.
    /// Throws ``RFBError/connectionClosed`` if the stream ends first.
    func readExactly(_ count: Int) async throws -> [UInt8]
}

public extension RFBByteSource {
    func readUInt8() async throws -> UInt8 {
        try await readExactly(1)[0]
    }

    func readUInt16() async throws -> UInt16 {
        let b = try await readExactly(2)
        return (UInt16(b[0]) << 8) | UInt16(b[1])
    }

    func readInt32() async throws -> Int32 {
        Int32(bitPattern: try await readUInt32())
    }

    func readUInt32() async throws -> UInt32 {
        let b = try await readExactly(4)
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    /// Reads a 32-bit big-endian length prefix followed by that many bytes.
    func readLengthPrefixedString() async throws -> String {
        let length = try await readUInt32()
        guard length > 0 else { return "" }
        let bytes = try await readExactly(Int(length))
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// An in-memory ``RFBByteSource`` for tests and replay.
public actor InMemoryByteSource: RFBByteSource {
    private let bytes: [UInt8]
    private var offset = 0

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public func readExactly(_ count: Int) async throws -> [UInt8] {
        guard count >= 0 else { throw RFBError.protocolViolation("negative read") }
        guard offset + count <= bytes.count else { throw RFBError.connectionClosed }
        defer { offset += count }
        return Array(bytes[offset ..< offset + count])
    }
}
