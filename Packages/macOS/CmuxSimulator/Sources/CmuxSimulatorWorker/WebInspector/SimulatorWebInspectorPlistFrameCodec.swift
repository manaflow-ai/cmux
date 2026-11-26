import Foundation

struct SimulatorWebInspectorPlistFrameCodec: Sendable {
    let maximumBodyLength: Int

    init(maximumBodyLength: Int = 64 * 1024 * 1024) {
        self.maximumBodyLength = maximumBodyLength
    }

    func encodeBody(_ value: [String: Any]) throws -> Data {
        let data = try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
        guard data.count <= maximumBodyLength else {
            throw SimulatorWebInspectorError.frameTooLarge(data.count)
        }
        return data
    }

    func decodeBody(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumBodyLength else {
            throw SimulatorWebInspectorError.frameTooLarge(data.count)
        }
        let value = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let dictionary = value as? [String: Any] else {
            throw SimulatorWebInspectorError.invalidPropertyList
        }
        return dictionary
    }

    func frame(_ value: [String: Any]) throws -> Data {
        let body = try encodeBody(value)
        let length = UInt32(body.count)
        var result = Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ])
        result.append(body)
        return result
    }

    func bodyLength(header: Data) throws -> Int {
        guard header.count == 4 else { throw SimulatorWebInspectorError.invalidFrame }
        let count = (UInt32(header[header.startIndex]) << 24)
            | (UInt32(header[header.startIndex + 1]) << 16)
            | (UInt32(header[header.startIndex + 2]) << 8)
            | UInt32(header[header.startIndex + 3])
        guard count <= UInt32(maximumBodyLength) else {
            throw SimulatorWebInspectorError.frameTooLarge(Int(count))
        }
        return Int(count)
    }
}
