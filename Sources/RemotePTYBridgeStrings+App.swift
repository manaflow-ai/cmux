import CmuxRemoteWorkspace
import Foundation

// User-facing PTY-bridge attach-failure strings resolve here, in the app
// target, so String(localized:) binds to the app bundle's localization
// tables (the package never localizes). Keys and default values are
// identical to the legacy WorkspaceRemotePTYBridgeServer.Session
// userFacingBridgeErrorMessage literals.
struct AppRemotePTYBridgeStrings: RemotePTYBridgeStrings {
    var missingPersistentPTYCapability: String {
        String(
            localized: "remoteDaemon.error.missingPersistentPTYCapability",
            defaultValue: "remote daemon does not support persistent SSH PTY sessions; reconnect the remote workspace to update cmux"
        )
    }

    var sessionEnded: String {
        String(
            localized: "remotePTYAttach.error.sessionEnded",
            defaultValue: "persistent SSH PTY session is no longer running"
        )
    }

    var inputBackedUp: String {
        String(
            localized: "remotePTYAttach.error.inputBackedUp",
            defaultValue: "remote PTY input is temporarily backed up"
        )
    }

    var daemonTimeout: String {
        String(
            localized: "remotePTYAttach.error.daemonTimeout",
            defaultValue: "remote daemon did not respond in time"
        )
    }

    func allocationDiagnostic(_ message: String) -> String {
        String(
            localized: "remotePTYAttach.error.allocationDiagnostic",
            defaultValue: "\(message)"
        )
    }

    var attachFailed: String {
        String(
            localized: "remotePTYAttach.error.attachFailed",
            defaultValue: "remote PTY attach failed"
        )
    }
}
