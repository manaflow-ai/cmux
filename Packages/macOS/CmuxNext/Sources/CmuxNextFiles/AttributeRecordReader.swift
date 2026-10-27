#if canImport(Darwin)
import Darwin

/// Reads one `getattrlistbulk(2)` record out of the batch buffer: little-endian integers, each checked
/// against the record's end, so a short or malformed record ends the read instead of running into the
/// next record or past the buffer. The pointer-free form of loading the kernel's packed layout, the way
/// Chromium reads a buffer it did not write (base/containers/span_reader.h, `SpanReader`). Every
/// attribute the Files listing asks for is an integer or a struct of integers.
struct AttributeRecordReader {
    private let bytes: [UInt8]
    /// Where the record starts in the batch buffer.
    let start: Int
    /// The record's length, its own length field included.
    let length: Int
    /// The next byte to read.
    private(set) var position: Int

    /// The record at `start` in `bytes`; nil when its length field is short (under the field itself) or
    /// runs past the buffer.
    init?(_ bytes: [UInt8], at start: Int) {
        guard start >= 0, bytes.count - start >= 4 else { return nil }
        var length = 0
        for index in 0..<4 { length |= Int(bytes[start + index]) << (8 * index) }
        guard length >= 4, length <= bytes.count - start else { return nil }
        self.bytes = bytes
        self.start = start
        self.length = length
        position = start + 4
    }

    /// The next `MemoryLayout<T>.size` bytes as a little-endian integer; nil (and nothing read) when they
    /// run past the record's end.
    mutating func read<T: UnsignedInteger & FixedWidthInteger>(_: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard size <= start + length - position else { return nil }
        var value: T = 0
        for index in 0..<size { value |= T(bytes[position + index]) << (8 * index) }
        position += size
        return value
    }

    /// A `timespec` (seconds, then nanoseconds, 8 bytes each); nil when it runs past the record's end.
    mutating func readTime() -> timespec? {
        guard 2 * MemoryLayout<UInt64>.size <= start + length - position,
              let seconds = read(UInt64.self), let nanoseconds = read(UInt64.self) else { return nil }
        return timespec(tv_sec: Int(Int64(bitPattern: seconds)), tv_nsec: Int(Int64(bitPattern: nanoseconds)))
    }

    /// Skips `count` bytes; false (and nothing skipped) when they run past the record's end.
    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, count <= start + length - position else { return false }
        position += count
        return true
    }

    /// The UTF-8 text of `length` bytes at `offset` in the batch buffer, up to its first NUL (an
    /// `attrreference_t`'s target); nil when any of the bytes lies outside the record.
    func text(at offset: Int, length textLength: Int) -> String? {
        guard offset >= start, textLength >= 0, offset <= start + length,
              textLength <= start + length - offset else { return nil }
        return String(decoding: bytes[offset..<(offset + textLength)].prefix { $0 != 0 }, as: UTF8.self)
    }
}
#endif
