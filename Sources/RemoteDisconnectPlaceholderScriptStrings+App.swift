import CmuxRemoteSession
import Foundation

// The remote-disconnect banner strings resolve here, in the app target, so
// String(localized:) binds to the app bundle's localization tables (the package
// never localizes). Keys and default values are identical to the legacy
// Workspace.remoteDisconnectPlaceholderScript inline String(localized:) calls.
extension RemoteDisconnectPlaceholderScript.Strings {
    /// The app-bundle-resolved disconnect banner strings, built at the call site
    /// and injected into each `RemoteDisconnectPlaceholderScript`.
    static var appLocalized: RemoteDisconnectPlaceholderScript.Strings {
        RemoteDisconnectPlaceholderScript.Strings(
            sessionEndedFormat: String(
                localized: "remote.disconnectBanner.sessionEnded",
                defaultValue: "[cmux] remote session disconnected: %s"
            ),
            reconnectHint: String(
                localized: "remote.disconnectBanner.reconnectHint",
                defaultValue: "[cmux] Press Enter to reconnect. This terminal will stay disconnected until then."
            ),
            reconnectUnavailableHint: String(
                localized: "remote.disconnectBanner.reconnectUnavailableHint",
                defaultValue: "[cmux] Reconnect this workspace from the sidebar or by running the original cmux remote command again."
            )
        )
    }
}
