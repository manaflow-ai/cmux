import Foundation

/// One region of bytes the connection's reader filled (attach-frames-v1): the frame payloads
/// cut from it are slices that share its storage, never copies. Chrome hands large IPC payloads on the
/// same way, as a `mojo_base::BigBuffer` (mojo/public/cpp/base/big_buffer.h).
final class TerminalReadBuffer: Sendable {
    let bytes: Data

    init(_ bytes: Data) {
        self.bytes = bytes
    }
}

/// Bytes `range` (indices of ``TerminalReadBuffer/bytes``) of one read buffer: a frame payload or a part of one.
struct TerminalFrameBytes: Sendable {
    let buffer: TerminalReadBuffer
    let range: Range<Data.Index>

    /// Nil when `range` is not inside the buffer.
    init?(buffer: TerminalReadBuffer, range: Range<Data.Index>) {
        guard range.lowerBound >= buffer.bytes.startIndex, range.upperBound <= buffer.bytes.endIndex else { return nil }
        self.buffer = buffer
        self.range = range
    }

    /// All of `data`, as a buffer of its own.
    init(_ data: Data) {
        buffer = TerminalReadBuffer(data)
        range = data.startIndex ..< data.endIndex
    }

    var count: Int { range.count }

    /// The bytes, as a `Data` slice that shares the buffer's storage.
    var data: Data { buffer.bytes.dropFirst(range.lowerBound - buffer.bytes.startIndex).prefix(range.count) }

    /// The `length` bytes from `start` (counted from the first byte of these); nil past the end.
    func slice(from start: Int, length: Int) -> TerminalFrameBytes? {
        guard start >= 0, length >= 0, start <= count - length else { return nil }
        let lower = range.lowerBound + start
        return TerminalFrameBytes(buffer: buffer, range: lower ..< lower + length)
    }

    /// The bytes from `start` to the end; nil past the end.
    func suffix(from start: Int) -> TerminalFrameBytes? {
        slice(from: start, length: count - start)
    }

    /// The little-endian `UInt32` at `start`; nil past the end.
    func littleEndianUInt32(at start: Int) -> UInt32? {
        guard let word = slice(from: start, length: 4) else { return nil }
        return word.data.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32(truncatingIfNeeded: $1) }
    }
}

/// PTY output bytes `offset ..< end` of an attach stream, still in the read buffer they came in.
struct TerminalOutputSpan: Sendable {
    /// The absolute PTY offset of the first byte (the OUTPUT frame's aux).
    let offset: UInt64
    let bytes: TerminalFrameBytes

    /// The offset just past the last byte.
    var end: UInt64 { offset &+ UInt64(truncatingIfNeeded: bytes.count) }

    /// `self` and `next` as one span when `next` continues it both in the PTY stream and in the same read
    /// buffer, so the joined bytes are one slice and nothing is copied; nil otherwise.
    func joined(with next: TerminalOutputSpan) -> TerminalOutputSpan? {
        guard next.bytes.buffer === bytes.buffer, next.bytes.range.lowerBound == bytes.range.upperBound,
              next.offset == end,
              let joined = TerminalFrameBytes(buffer: bytes.buffer,
                                              range: bytes.range.lowerBound ..< next.bytes.range.upperBound)
        else { return nil }
        return TerminalOutputSpan(offset: offset, bytes: joined)
    }

    /// The bytes from PTY offset `start` on, as a slice of the same buffer; nil when `start` is outside the span.
    func dropping(before start: UInt64) -> TerminalOutputSpan? {
        guard start >= offset, start <= end, let skip = Int(exactly: start - offset),
              let rest = bytes.suffix(from: skip)
        else { return nil }
        return TerminalOutputSpan(offset: start, bytes: rest)
    }
}
