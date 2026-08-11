internal import CmuxAgentChat
internal import CmuxMobileRPC
internal import Foundation

/// Keeps artifact availability separate from control-transport reachability.
struct MobileChatArtifactFailureClassifier: Sendable {
    func classify(_ error: any Error) -> ChatArtifactError {
        guard let connectionError = error as? MobileShellConnectionError else {
            return .loadFailed
        }
        switch connectionError {
        case .connectionClosed:
            return .macUnreachable
        case .invalidResponse, .requestTimedOut, .transportWriteTimedOut,
             .connectAttemptGated, .insecureManualRoute, .attachTicketExpired,
             .authorizationFailed, .accountMismatch, .routeCleanupBlocked:
            return .loadFailed
        case .rpcError(let code, _):
            switch code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "invalid_params":
                return .invalidParams
            case "not_found":
                return .sessionNotFound
            case "forbidden":
                return .forbidden
            case "file_not_found":
                return .fileNotFound
            case "unsupported_media":
                return .unsupportedMedia
            case "unavailable":
                return .unavailable
            default:
                return .loadFailed
            }
        }
    }
}
