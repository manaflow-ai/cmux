import Foundation

/// Buffered, pull-based reads over a transport. Reads that the buffer can
/// serve never suspend, so decoders pay for the network only when a chunk is
/// actually missing. Owned by one session task; not shared.
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
        try await ensure(count)
        defer { offset += count }
        return Array(buffer[offset ..< offset + count])
    }

    /// Hands `count` contiguous bytes to `body`, then consumes them.
    func withBytes<R>(_ count: Int, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) async throws -> R {
        try await ensure(count)
        defer { offset += count }
        return try buffer.withUnsafeBufferPointer { all in
            try body(UnsafeBufferPointer(rebasing: all[offset ..< offset + count]))
        }
    }

    func skip(_ count: Int) async throws {
        try await ensure(count)
        offset += count
    }

    func u8() async throws -> UInt8 {
        try await ensure(1)
        defer { offset += 1 }
        return buffer[offset]
    }

    func u16() async throws -> UInt16 {
        try await ensure(2)
        defer { offset += 2 }
        return UInt16(buffer[offset]) << 8 | UInt16(buffer[offset + 1])
    }

    func u32() async throws -> UInt32 {
        try await ensure(4)
        defer { offset += 4 }
        return UInt32(buffer[offset]) << 24 | UInt32(buffer[offset + 1]) << 16
            | UInt32(buffer[offset + 2]) << 8 | UInt32(buffer[offset + 3])
    }

    func s32() async throws -> Int32 {
        Int32(bitPattern: try await u32())
    }

    /// A little-endian BGRX pixel (the negotiated format), alpha forced opaque.
    func pixel() async throws -> UInt32 {
        try await ensure(4)
        defer { offset += 4 }
        return UInt32(buffer[offset]) | UInt32(buffer[offset + 1]) << 8 | UInt32(buffer[offset + 2]) << 16 | 0xFF00_0000
    }

    /// A 32-bit length followed by that many bytes (bounded by `limit`).
    func lengthPrefixedString(limit: Int = 1 << 20) async throws -> String {
        let length = Int(try await u32())
        guard length <= limit else { throw RFBError.protocolViolation("string of \(length) bytes") }
        let bytes = try await bytes(length)
        return String(decoding: bytes, as: UTF8.self)
    }
}
