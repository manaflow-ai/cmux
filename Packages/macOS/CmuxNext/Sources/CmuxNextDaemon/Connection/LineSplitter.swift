import Darwin
import Foundation

/// One binary frame of a connection that negotiated
/// `terminal-binary-frames-v1` (cmux-tui spec/transports.md, "Binary
/// frames"): `0x00, kind:u8, flags:u16le, length:u32le, payload`.
nonisolated struct BinaryFrame: Sendable, Equatable {
    /// `output`: `surface:u64le, generation:u64le, offset:u64le`, then PTY bytes.
    static let output: UInt8 = 0x01
    /// An event whose `data` travels beside its JSON: `json_len:u32le, json, data`.
    static let eventData: UInt8 = 0x02
    /// `send` input (client to daemon): `id:u64le, surface:u64le`, then bytes.
    static let input: UInt8 = 0x11
    /// `output`: `generation` and `offset` are present (snapshot attach).
    static let outputPosition: UInt16 = 0x0001
    static let marker: UInt8 = 0x00
    static let headerBytes = 8

    var kind: UInt8
    var flags: UInt16
    var payload: Data

    /// The whole input frame for `send {id, surface, bytes}`.
    static func inputFrame(id: UInt64, surface: UInt64, bytes: Data) -> Data {
        var frame = Data(capacity: headerBytes + 16 + bytes.count)
        frame.append(contentsOf: [marker, input, 0, 0])
        frame.appendLittleEndian(UInt32(16 + bytes.count))
        frame.appendLittleEndian(id)
        frame.appendLittleEndian(surface)
        frame.append(bytes)
        return frame
    }

    /// The little-endian `UInt64` at `offset` of the payload.
    func word(at offset: Int) -> UInt64? {
        guard offset >= 0, payload.count >= offset + 8 else { return nil }
        return payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }.littleEndian
    }
}

extension Data {
    fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

/// Splits a byte stream into newline-terminated lines (JSON Lines) and, on a
/// connection that negotiated them, binary frames. A frame starts with NUL,
/// which never starts a JSON line, so each message boundary says which of
/// the two follows.
///
/// Each byte is searched for a newline once: the buffered rest is one
/// unfinished line, so only the bytes appended last can end it, and each
/// complete line is copied out once. Rescanning the rest on every read was
/// quadratic in the line size, and a 10 MiB terminal replay (one line of
/// about 14 MB) missed the 10 s attach deadline (c997498fd634).
/// `scannedBytes` counts the search work, so tests check the linear bound
/// without timing it.
nonisolated struct LineSplitter {
    /// The unfinished line or frame.
    private(set) var pending = Data()
    /// Bytes searched for a newline so far.
    private(set) var scannedBytes = 0
    /// Bytes of `pending` already searched for a newline.
    private var scanned = 0
    /// A frame header announced more than this: the stream is unusable.
    private(set) var oversizedFrame = false

    /// Appends `bytes` and passes each complete, nonempty line (without its
    /// newline) to `line`, in order.
    mutating func append(_ bytes: some Collection<UInt8>, line: (Data) -> Void) {
        append(bytes, maxFrameBytes: nil, line: line, frame: { _ in })
    }

    /// Appends `bytes` and passes each complete line to `line` and each
    /// complete binary frame to `frame`, in stream order. A frame whose
    /// payload exceeds `maxFrameBytes` sets `oversizedFrame` and stops; with
    /// nil, a NUL is line content as it was before frames existed.
    mutating func append(_ bytes: some Collection<UInt8>, maxFrameBytes: Int?,
                         line: (Data) -> Void, frame: (BinaryFrame) -> Void) {
        pending.append(contentsOf: bytes)
        // Locals: `self` may not be written while `pending` is borrowed.
        var start = 0
        var scanned = scanned
        var searched = 0
        var oversized = oversizedFrame
        let count = pending.count
        pending.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while start < count, !oversized {
                if let maxFrameBytes, base.load(fromByteOffset: start, as: UInt8.self) == BinaryFrame.marker {
                    guard count - start >= BinaryFrame.headerBytes else { break }
                    let length = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: start + 4, as: UInt32.self)))
                    guard length <= maxFrameBytes else {
                        oversized = true
                        break
                    }
                    guard count - start - BinaryFrame.headerBytes >= length else { break }
                    let kind = base.load(fromByteOffset: start + 1, as: UInt8.self)
                    let flags = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: start + 2, as: UInt16.self))
                    let payload = Data(bytes: base + start + BinaryFrame.headerBytes, count: length)
                    frame(BinaryFrame(kind: kind, flags: flags, payload: payload))
                    start += BinaryFrame.headerBytes + length
                    scanned = start
                    continue
                }
                let from = max(scanned, start)
                guard from < count, let hit = memchr(base + from, 0x0A, count - from) else {
                    searched += count - from
                    scanned = count
                    break
                }
                let end = base.distance(to: UnsafeRawPointer(hit))
                // memchr read up to the newline it found.
                searched += end + 1 - from
                if end > start {
                    line(Data(bytes: base + start, count: end - start))
                }
                start = end + 1
                scanned = start
            }
        }
        scannedBytes += searched
        oversizedFrame = oversized
        if start > 0 {
            pending.removeSubrange(pending.startIndex..<(pending.startIndex + start))
        }
        self.scanned = scanned - start
    }

    /// Offsets (from `data.startIndex`) of every newline at or after
    /// `offset`, and the number of bytes searched for them.
    static func newlineOffsets(in data: Data, from offset: Int) -> (offsets: [Int], searched: Int) {
        data.withUnsafeBytes { raw -> ([Int], Int) in
            guard let base = raw.baseAddress, offset < raw.count else { return ([], 0) }
            var offsets: [Int] = []
            var position = offset
            while position < raw.count, let hit = memchr(base + position, 0x0A, raw.count - position) {
                let found = base.distance(to: UnsafeRawPointer(hit))
                offsets.append(found)
                position = found + 1
            }
            // memchr reads up to the newline it finds, or to the end.
            return (offsets, raw.count - offset)
        }
    }
}
