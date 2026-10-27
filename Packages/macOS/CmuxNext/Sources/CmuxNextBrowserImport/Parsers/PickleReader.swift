import Foundation

/// Reads Chromium `base::Pickle` payloads: a uint32 payload size, then
/// 4-byte aligned fields (int32, int64, length-prefixed UTF-8 and UTF-16
/// strings). Fields are taken from the front of what is left, so a short
/// payload or a length the file lies about yields nil, never a trap
/// (base/pickle.cc's PickleIterator checks each read against the end the same way).
struct PickleReader {
    /// What is left to read.
    private var rest: ArraySlice<UInt8>

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard let size = Self.uint32(bytes), size.widened <= bytes.count - 4 else { return nil }
        rest = bytes.dropFirst(4)
    }

    /// A raw struct payload (not a pickle): fields from offset 0.
    init(raw data: Data) {
        rest = ArraySlice(data)
    }

    mutating func int32() -> Int32? {
        guard let word = Self.uint32(rest) else { return nil }
        rest = rest.dropFirst(4)
        return Int32(bitPattern: word)
    }

    mutating func int64() -> Int64? {
        guard let low = int32(), let high = int32() else { return nil }
        return Int64(truncatingIfNeeded: high) << 32 | Int64(truncatingIfNeeded: UInt32(bitPattern: low))
    }

    mutating func string() -> String? {
        guard let length = int32()?.widened, length >= 0, length <= rest.count else { return nil }
        let value = String(decoding: rest.prefix(length), as: UTF8.self)
        rest = rest.dropFirst(Self.aligned(length))
        return value
    }

    mutating func string16() -> String? {
        guard let length = int32()?.widened, length >= 0, length * 2 <= rest.count else { return nil }
        let field = rest.prefix(length * 2)
        let units = stride(from: 0, to: field.count, by: 2).map { field.dropFirst($0).prefix(2).littleEndian(as: UInt16.self) }
        rest = rest.dropFirst(Self.aligned(length * 2))
        return String(decoding: units, as: UTF16.self)
    }

    private static func aligned(_ count: Int) -> Int { (count + 3) & ~3 }

    /// The little-endian uint32 that starts `bytes`, or nil when fewer than 4 bytes are there.
    static func uint32<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> UInt32? {
        let word = bytes.prefix(4)
        guard word.count == 4 else { return nil }
        return word.reversed().reduce(UInt32.zero) { $0 << 8 | UInt32(truncatingIfNeeded: $1) }
    }
}
