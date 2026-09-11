import CmuxFoundation
import Foundation

extension TerminalController {
    /// Returns the machine-readable code placed on v2 remote-PTY failures.
    nonisolated func v2RemotePTYErrorCode(_ error: any Error) -> String {
        RemotePTYErrorCode.code(for: error)
    }

    /// Resolves the app-bundle human message for a remote-PTY failure.
    nonisolated func v2RemotePTYUserFacingErrorMessage(_ error: any Error) -> String {
        localizedRemotePTYErrorMessage(
            for: RemotePTYErrorPresentation(error: error).kind
        )
    }

    /// Maps legacy remote-PTY text for older daemon/app pairs and display.
    nonisolated func v2RemotePTYUserFacingErrorMessage(_ message: String) -> String {
        v2RemotePTYUserFacingErrorMessage(message, code: nil)
    }

    private nonisolated func v2RemotePTYUserFacingErrorMessage(
        _ message: String,
        code: String?
    ) -> String {
        localizedRemotePTYErrorMessage(
            for: RemotePTYErrorPresentation(message: message, code: code).kind
        )
    }

    private nonisolated func localizedRemotePTYErrorMessage(
        for kind: RemotePTYErrorPresentation.Kind
    ) -> String {
        switch kind {
        case .capabilityMissing:
            return String(
                localized: "remoteDaemon.error.missingPersistentPTYCapability",
                defaultValue: "remote daemon does not support persistent SSH PTY sessions; reconnect the remote workspace to update cmux"
            )
        case .sessionNotFound:
            return String(
                localized: "remotePTYAttach.error.sessionEnded",
                defaultValue: "persistent SSH PTY session is no longer running"
            )
        case .inputQueueFull:
            return String(
                localized: "remotePTYAttach.error.inputBackedUp",
                defaultValue: "remote PTY input is temporarily backed up"
            )
        case .connectionInactive:
            return String(
                localized: "remotePTYAttach.error.connectionInactive",
                defaultValue: "remote connection is not active"
            )
        case .daemonNotReady:
            return String(
                localized: "remotePTYAttach.error.daemonNotReady",
                defaultValue: "remote daemon is not ready"
            )
        case .missingWorkspaceID, .missingSessionID:
            return String(
                localized: "remotePTYAttach.error.reconnectRequired",
                defaultValue: "Reconnect the remote workspace and try again."
            )
        case .timeout:
            return String(
                localized: "remotePTYAttach.error.daemonTimeout",
                defaultValue: "remote daemon did not respond in time"
            )
        case .generic:
            return String(
                localized: "remotePTYAttach.error.operationFailed",
                defaultValue: "remote PTY operation failed"
            )
        }
    }
}
