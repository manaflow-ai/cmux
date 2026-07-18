internal import Foundation

/// Reads exact network-byte-order renderer-control fields from one payload.
struct RendererControlWireReader {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    var remainingCount: Int {
        data.count - offset
    }

    var isAtEnd: Bool {
        offset == data.count
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else {
            throw RendererControlError.truncatedFrame
        }
        defer { offset += count }
        return Data(data[offset..<(offset + count)])
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        Array(try readData(count: count))
    }

    mutating func readUInt8() throws -> UInt8 {
        try readBytes(count: 1)[0]
    }

    mutating func readUInt16() throws -> UInt16 {
        try readBytes(count: 2).reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    mutating func readUInt32() throws -> UInt32 {
        try readBytes(count: 4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        try readBytes(count: 8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readUUID() throws -> UUID {
        let bytes = try readBytes(count: 16)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
