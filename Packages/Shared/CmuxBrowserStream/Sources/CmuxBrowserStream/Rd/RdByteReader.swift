import Foundation

/// Little-endian reader over one datagram or payload (cmux-rd-proto `Reader`).
struct RdByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var isEmpty: Bool { offset == bytes.count }
    var remaining: Int { bytes.count - offset }

    mutating func u8() throws(RdWireError) -> UInt8 {
        guard remaining >= 1 else { throw RdWireError("truncated") }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws(RdWireError) -> UInt16 { UInt16(truncatingIfNeeded: try little(2)) }
    mutating func u32() throws(RdWireError) -> UInt32 { UInt32(truncatingIfNeeded: try little(4)) }
    mutating func u64() throws(RdWireError) -> UInt64 { try little(8) }
    mutating func i32() throws(RdWireError) -> Int32 { Int32(bitPattern: try u32()) }

    mutating func bool() throws(RdWireError) -> Bool {
        switch try u8() {
        case 0: return false
        case 1: return true
        default: throw RdWireError("bool")
        }
    }

    mutating func take(_ count: Int) throws(RdWireError) -> Data {
        guard count >= 0, remaining >= count else { throw RdWireError("truncated") }
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }

    mutating func rest() -> Data {
        defer { offset = bytes.count }
        return Data(bytes[offset...])
    }

    private mutating func little(_ count: Int) throws(RdWireError) -> UInt64 {
        guard remaining >= count else { throw RdWireError("truncated") }
        var value: UInt64 = 0
        for i in 0..<count {
            value |= UInt64(bytes[offset + i]) << (8 * UInt64(i))
        }
        offset += count
        return value
    }
}
