import Foundation

enum SimulatorWebInspectorPlistFrameCodec {
    static let maximumBodyLength = 64 * 1024 * 1024

    static func encodeBody(_ value: [String: Any]) throws -> Data {
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

    static func decodeBody(_ data: Data) throws -> [String: Any] {
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

    static func frame(_ value: [String: Any]) throws -> Data {
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

    static func bodyLength(header: Data) throws -> Int {
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

enum SimulatorWebInspectorError: Error, Equatable, Sendable {
    case unavailable(String)
    case invalidSocketPath
    case socketFailure(Int32)
    case invalidFrame
    case frameTooLarge(Int)
    case invalidPropertyList
    case invalidMessage
    case targetNotFound
    case targetInUse
    case sessionUnavailable
    case commandTooLarge(Int)
    case wrapperAcknowledgementBacklog(Int)
    case wrapperIdentifierCollision
    case timedOut(String)
    case remoteCommand(String)
    case transportClosed
}

extension SimulatorWebInspectorError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .unavailable(detail): detail
        case .invalidSocketPath: "Web Inspector reported an invalid Simulator socket path."
        case let .socketFailure(code): "The Web Inspector socket failed with errno \(code)."
        case .invalidFrame: "Web Inspector sent an invalid frame."
        case let .frameTooLarge(length): "Web Inspector sent an oversized \(length)-byte plist frame."
        case .invalidPropertyList: "Web Inspector sent a non-dictionary property list."
        case .invalidMessage: "The Web Inspector message was not valid JSON."
        case .targetNotFound: "The selected Web Inspector target no longer exists."
        case .targetInUse: "Another inspector is already attached to this target."
        case .sessionUnavailable: "Attach a Web Inspector target before sending commands."
        case let .commandTooLarge(length): "The \(length)-byte inspector command exceeds the one MiB limit."
        case let .wrapperAcknowledgementBacklog(count):
            "Web Inspector has \(count) unacknowledged target wrappers."
        case .wrapperIdentifierCollision:
            "A Web Inspector Target command reused an outstanding internal wrapper identifier."
        case let .timedOut(operation): "Web Inspector timed out while waiting for \(operation)."
        case let .remoteCommand(message): "Web Inspector rejected a command: \(message)"
        case .transportClosed: "The Web Inspector socket closed."
        }
    }
}
