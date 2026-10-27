import Foundation

/// Buffered, pull-based reads over a transport. Reads that the buffer can
/// serve never suspend, so decoders pay for the network only when a chunk is
/// actually missing. Owned by one session task; not shared.
///
/// Every read goes through `withBytes`, which hands out a slice of exactly the
/// bytes `ensure` buffered: no read indexes the buffer, and a negative count
/// (a decoder's arithmetic gone wrong) is `RFBError.protocolViolation`.
final class RFBReader {
    private let transport: any RFBTransport
    private var buffer: [UInt8] = []
    private var offset = 0
    /// Bytes received from the transport so far.
    private(set) var bytesReceived = 0

    init(transport: any RFBTransport) {
        self.transport = transport
    }

    /// Buffered bytes not yet consumed.
    var available: Int { buffer.count - offset }

    /// Waits until `count` bytes are buffered.
    func ensure(_ count: Int) async throws {
        while available < count {
            if offset > 0, offset >= buffer.count / 2 {
                buffer.removeFirst(offset)
                offset = 0
            }
            let chunk = try await transport.receive()
            bytesReceived += chunk.count
            buffer.append(contentsOf: chunk)
        }
    }

    func bytes(_ count: Int) async throws -> [UInt8] {
        guard count > 0 else { return [] }
        return try await withBytes(count) { Array($0) }
    }

    /// Hands `count` buffered bytes to `body` as a slice of the read buffer (no copy;
    /// its indices start at the slice's `startIndex`), then consumes them.
    func withBytes<R>(_ count: Int, _ body: (ArraySlice<UInt8>) throws -> R) async throws -> R {
        guard count >= 0 else { throw RFBError.protocolViolation("a read of \(count) bytes") }
        try await ensure(count)
        defer { offset += count }
        return try body(buffer.dropFirst(offset).prefix(count))
    }

    func skip(_ count: Int) async throws {
        guard count >= 0 else { throw RFBError.protocolViolation("a skip of \(count) bytes") }
        try await ensure(count)
        offset += count
    }

    func u8() async throws -> UInt8 {
        try await withBytes(1) { $0.bigEndian(as: UInt8.self) }
    }

    func u16() async throws -> UInt16 {
        try await withBytes(2) { $0.bigEndian(as: UInt16.self) }
    }

    func u32() async throws -> UInt32 {
        try await withBytes(4) { $0.bigEndian(as: UInt32.self) }
    }

    func s32() async throws -> Int32 {
        Int32(bitPattern: try await u32())
    }

    /// A wire u8 as a count or coordinate.
    func u8Int() async throws -> Int {
        try await u8().widened
    }

    /// A wire u16 as a count or coordinate.
    func u16Int() async throws -> Int {
        try await u16().widened
    }

    /// A wire u32 as a length: `RFBError.protocolViolation` when it does not fit an `Int`.
    func u32Int(_ what: String) async throws -> Int {
        try await u32().rfbCount(what)
    }

    /// A little-endian BGRX pixel (the negotiated format), alpha forced opaque.
    func pixel() async throws -> UInt32 {
        try await withBytes(4) { $0.prefix(3).littleEndian(as: UInt32.self) | 0xFF00_0000 }
    }

    /// A 32-bit length followed by that many bytes (bounded by `limit`).
    func lengthPrefixedString(limit: Int = 1 << 20) async throws -> String {
        let length = try await u32Int("a string length")
        guard length <= limit else { throw RFBError.protocolViolation("string of \(length) bytes") }
        let bytes = try await bytes(length)
        return String(decoding: bytes, as: UTF8.self)
    }
}
