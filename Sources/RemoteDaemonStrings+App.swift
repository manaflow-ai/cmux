import CmuxRemoteDaemon
import Foundation

// User-facing daemon strings resolve here, in the app target, so
// String(localized:) binds to the app bundle's localization tables (the
// package never localizes). Keys and default values are identical to the
// legacy remoteDaemonMissingRequiredCapabilitiesMessage free function.
extension RemoteDaemonStrings {
    /// The app-bundle-resolved daemon strings, built at the composition root
    /// and injected through the remote service initializers.
    static var appLocalized: RemoteDaemonStrings {
        RemoteDaemonStrings(
            missingPersistentPTYCapability: String(
                localized: "remoteDaemon.error.missingPersistentPTYCapability",
                defaultValue: "remote daemon does not support persistent SSH PTY sessions; reconnect the remote workspace to update cmux"
            ),
            missingRequiredFunctionality: String(
                localized: "remoteDaemon.error.missingRequiredFunctionality",
                defaultValue: "remote daemon is missing required functionality; reconnect the remote workspace to update cmux"
            ),
            cloudNotificationClearWorkspaceInvalid: String(
                localized: "remoteDaemon.error.cloudNotificationClearWorkspaceInvalid",
                defaultValue: "Cloud CLI notification clear requires a valid workspace_id"
            ),
            cloudNotificationClearWorkspaceDenied: String(
                localized: "remoteDaemon.error.cloudNotificationClearWorkspaceDenied",
                defaultValue: "Cloud CLI notification clear target does not match this workspace"
            ),
            cloudNotificationClearSurfaceInvalid: String(
                localized: "remoteDaemon.error.cloudNotificationClearSurfaceInvalid",
                defaultValue: "Cloud CLI notification clear requires a valid surface_id"
            ),
            cloudNotificationClearCallerInvalid: String(
                localized: "socket.notification.clear.callerInvalid",
                defaultValue: "Missing or invalid caller"
            ),
            cloudNotificationClearCallerSelectorsRequireCaller: String(
                localized: "socket.notification.clear.callerSelectorsRequireCaller",
                defaultValue: "caller-only selectors require caller=true"
            ),
            cloudNotificationClearCallerScopeConflict: String(
                localized: "socket.notification.clear.callerScopeConflict",
                defaultValue: "caller clear cannot be combined with workspace_id, tab_id, or surface_id"
            ),
            cloudNotificationClearEncodingFailed: String(
                localized: "remoteDaemon.error.cloudNotificationClearEncodingFailed",
                defaultValue: "Failed to encode Cloud CLI request"
            )
        )
    }
}
