import Foundation

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
    case reservedIdentifier
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
        case .reservedIdentifier:
            "The Web Inspector command used an identifier reserved for cmux internal requests."
        case let .timedOut(operation): "Web Inspector timed out while waiting for \(operation)."
        case let .remoteCommand(message): "Web Inspector rejected a command: \(message)"
        case .transportClosed: "The Web Inspector socket closed."
        }
    }
}
