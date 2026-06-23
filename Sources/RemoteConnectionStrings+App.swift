import CmuxRemoteSession
import Foundation

// User-facing connection-lifecycle strings resolve here, in the app target, so
// String(localized:) binds to the app bundle's localization tables (the package
// never localizes). Keys and default values are identical to the legacy
// Workspace inline String(localized:) calls.
extension RemoteConnectionStrings {
    /// The app-bundle-resolved connection strings, built at the composition root
    /// and injected into each workspace's `RemoteConnectionCoordinator`.
    static var appLocalized: RemoteConnectionStrings {
        RemoteConnectionStrings(
            terminalDisconnectedDetail: String(
                localized: "remote.status.terminalDisconnected",
                defaultValue: "Remote terminal session disconnected"
            ),
            suspendedStatusEntryFormat: String(
                localized: "remote.statusEntry.suspended",
                defaultValue: "SSH reconnect paused (%@): %@"
            ),
            suspendedNotificationTitle: String(
                localized: "remote.notification.suspendedTitle",
                defaultValue: "SSH Reconnect Paused"
            ),
            disconnectBannerSessionEndedFormat: String(
                localized: "remote.disconnectBanner.sessionEnded",
                defaultValue: "[cmux] remote session disconnected: %s"
            ),
            disconnectBannerReconnectHint: String(
                localized: "remote.disconnectBanner.reconnectHint",
                defaultValue: "[cmux] Press Enter to reconnect. This terminal will stay disconnected until then."
            ),
            disconnectBannerReconnectUnavailableHint: String(
                localized: "remote.disconnectBanner.reconnectUnavailableHint",
                defaultValue: "[cmux] Reconnect this workspace from the sidebar or by running the original cmux remote command again."
            )
        )
    }
}
