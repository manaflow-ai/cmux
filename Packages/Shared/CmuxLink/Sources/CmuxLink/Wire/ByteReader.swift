import Foundation

/// Little-endian reader for `LinkFrame`. Every read is bounds checked.
struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var isAtEnd: Bool { offset == data.endIndex }

    mutating func u8() throws(LinkFrameError) -> UInt8 {
        guard offset < data.endIndex else { throw .truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u16() throws(LinkFrameError) -> UInt16 { try integer() }

    mutating func u32() throws(LinkFrameError) -> UInt32 { try integer() }

    mutating func u64() throws(LinkFrameError) -> UInt64 { try integer() }

    mutating func bytes(_ count: Int) throws(LinkFrameError) -> Data {
        guard count >= 0, data.endIndex - offset >= count else { throw .truncated }
        defer { offset += count }
        return Data(data[offset..<(offset + count)])
    }

    mutating func rest() -> Data {
        defer { offset = data.endIndex }
        return Data(data[offset..<data.endIndex])
    }

    private mutating func integer<T: FixedWidthInteger>() throws(LinkFrameError) -> T {
        let size = MemoryLayout<T>.size
        guard data.endIndex - offset >= size else { throw .truncated }
        var value: T = 0
        for index in 0..<size {
            value |= T(data[offset + index]) << (8 * index)
        }
        offset += size
        return value
    }
}
