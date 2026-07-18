internal import Foundation

/// Reads one validated-length, network-byte-order frame metadata record.
struct TerminalRenderWireReader {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    var isAtEnd: Bool {
        offset == data.count
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, offset <= data.count - count else {
            throw TerminalRenderFrameProtocolError.truncatedWireRecord
        }
        defer { offset += count }
        return Array(data[offset..<(offset + count)])
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readBytes(count: MemoryLayout<UInt16>.size)
        return bytes.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(count: MemoryLayout<UInt32>.size)
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readBytes(count: MemoryLayout<UInt64>.size)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
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
