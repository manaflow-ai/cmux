internal import CmuxAgentChat
internal import CmuxMobileRPC
internal import Foundation

/// Preserves file, request, authorization, and transport failures across RPC scopes.
struct MobileArtifactFailureClassifier: Sendable {
    func classify(_ error: any Error, method: String? = nil) -> ChatArtifactError {
        if let artifactError = error as? ChatArtifactError {
            return artifactError
        }
        if error is DecodingError {
            return .invalidResponse
        }
        guard let connectionError = error as? MobileShellConnectionError else {
            return .loadFailed
        }
        switch connectionError {
        case .connectionClosed:
            return .macUnreachable
        case .invalidResponse:
            return .invalidResponse
        case .requestTimedOut, .transportWriteTimedOut:
            return .requestTimedOut
        case .connectAttemptGated:
            return .connectionRecovering
        case .routeCleanupBlocked:
            return .connectionNeedsRestart
        case .insecureManualRoute:
            return .secureConnectionRequired
        case .attachTicketExpired:
            return .authenticationExpired
        case .authorizationFailed:
            return .authorizationFailed
        case .accountMismatch:
            return .accountMismatch
        case .rpcError(let code, _):
            switch code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "invalid_params":
                return .invalidParams
            case "session_not_found":
                return .sessionNotFound
            case "session_unavailable":
                return .sessionUnavailable
            case "terminal_not_found":
                return .terminalNotFound
            case "workspace_not_found":
                return .workspaceNotFound
            case "not_found":
                return legacyNotFoundFailure(method: method)
            case "not_a_repo":
                return .notRepository
            case "forbidden":
                return .forbidden
            case "file_not_found":
                return .fileNotFound
            case "permission_denied":
                return .permissionDenied
            case "not_directory":
                return .notDirectory
            case "not_regular_file":
                return .notRegularFile
            case "read_failed":
                return .fileReadFailed
            case "file_changed":
                return .fileChanged
            case "unsupported_media":
                return .unsupportedMedia
            case "corrupt_media":
                return .corruptMedia
            case "preview_failed":
                return .previewFailed
            case "unavailable":
                return .unavailable
            case "invalid_response":
                return .invalidResponse
            case "transfer_interrupted":
                return .transferInterrupted
            case "request_timed_out":
                return .requestTimedOut
            case "unsupported_transport":
                return .secureConnectionRequired
            case "method_not_found", "capability_disabled":
                return .unsupported
            default:
                return .loadFailed
            }
        }
    }

    private func legacyNotFoundFailure(method: String?) -> ChatArtifactError {
        guard let method else { return .sessionNotFound }
        if method.hasPrefix("mobile.terminal.artifact.") {
            return .terminalNotFound
        }
        if method.hasPrefix("mobile.workspace.changes.") {
            return .workspaceNotFound
        }
        return .sessionNotFound
    }
}
