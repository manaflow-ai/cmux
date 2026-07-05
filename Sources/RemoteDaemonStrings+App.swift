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
            )
        )
    }
}
