import Foundation

/// One `attach-frames-v1` OUTPUT frame (app-daemon-connection-DESIGN.md 3.2): a 16-byte little-endian
/// header (`u8 0xFF`, `u8 kind`, `u16 stream`, `u32 len`, `u64 offset`), then `len` raw PTY bytes.
/// The daemon sends each plain `output` of a Unix connection that declared the capability this way:
/// no JSON scan and no base64 decode on the reader thread.
struct AttachOutputFrame: Sendable, Equatable {
    /// The capability a terminal attach declares in `set-client-info` to get OUTPUT frames.
    static let capability = "attach-frames-v1"
    /// Frame kind 1: raw PTY bytes; the offset is that of the first payload byte.
    static let kindOutput: UInt8 = 1

    /// The attach stream (0: this connection's only attach, until `attach-streams-v1`).
    var stream: UInt16
    /// The absolute stream offset of the payload's first byte.
    var offset: UInt64
    var payload: Data

    /// Reads one whole frame (``LineSplitter`` hands frames over whole); nil when it is not an
    /// OUTPUT frame or its length does not match its header.
    init?(message: Data) {
        let header = LineSplitter.frameHeaderBytes
        guard message.count >= header else { return nil }
        let fields = message.withUnsafeBytes { raw -> (magic: UInt8, kind: UInt8, stream: UInt16, len: UInt32, offset: UInt64) in
            (raw.load(fromByteOffset: 0, as: UInt8.self),
             raw.load(fromByteOffset: 1, as: UInt8.self),
             UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 2, as: UInt16.self)),
             UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)),
             UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
        }
        guard fields.magic == LineSplitter.frameMagic, fields.kind == Self.kindOutput,
              Int(exactly: fields.len) == message.count - header
        else { return nil }
        stream = fields.stream
        offset = fields.offset
        payload = Data(message.dropFirst(header))
    }

    init(stream: UInt16 = 0, offset: UInt64, payload: Data) {
        self.stream = stream
        self.offset = offset
        self.payload = payload
    }

    /// The wire bytes of this frame (tests).
    var encoded: Data {
        var data = Data([LineSplitter.frameMagic, Self.kindOutput])
        withUnsafeBytes(of: stream.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: payload.count).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: offset.littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }
}
