import Foundation

/// Reads Chromium `base::Pickle` payloads: a uint32 payload size, then
/// 4-byte aligned fields (int32, int64, length-prefixed UTF-8 and UTF-16
/// strings). Every read is bounds-checked; a short payload yields nil.
struct PickleReader {
    private let bytes: [UInt8]
    private var offset: Int

    init?(_ data: Data) {
        bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let size = Int(Self.uint32(bytes, at: 0))
        guard size <= bytes.count - 4 else { return nil }
        offset = 4
    }

    /// A raw struct payload (not a pickle): fields from offset 0.
    init(raw data: Data) {
        bytes = [UInt8](data)
        offset = 0
    }

    mutating func int32() -> Int32? {
        guard offset + 4 <= bytes.count else { return nil }
        defer { offset += 4 }
        return Int32(bitPattern: Self.uint32(bytes, at: offset))
    }

    mutating func int64() -> Int64? {
        guard let low = int32(), let high = int32() else { return nil }
        return Int64(high) << 32 | Int64(UInt32(bitPattern: low))
    }

    mutating func string() -> String? {
        guard let length = int32(), length >= 0, offset + Int(length) <= bytes.count else { return nil }
        let value = String(decoding: bytes[offset..<offset + Int(length)], as: UTF8.self)
        offset += Self.aligned(Int(length))
        return value
    }

    mutating func string16() -> String? {
        guard let length = int32(), length >= 0 else { return nil }
        let byteCount = Int(length) * 2
        guard offset + byteCount <= bytes.count else { return nil }
        let units = stride(from: offset, to: offset + byteCount, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
        offset += Self.aligned(byteCount)
        return String(decoding: units, as: UTF16.self)
    }

    private static func aligned(_ count: Int) -> Int { (count + 3) & ~3 }

    static func uint32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }
}
