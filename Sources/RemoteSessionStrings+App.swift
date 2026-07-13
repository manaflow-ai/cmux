import CmuxRemoteSession
import Foundation

// User-facing connection-state strings resolve here, in the app target, so
// String(localized:) binds to the app bundle's localization tables (the
// package never localizes). Keys and default values are identical to the
// legacy controller's inline String(localized:) calls.
extension RemoteSessionStrings {
    /// The app-bundle-resolved session strings, built at the composition root
    /// and injected into each `RemoteSessionCoordinator`.
    static var appLocalized: RemoteSessionStrings {
        RemoteSessionStrings(
            connectedVMNoProxyFormat: String(
                localized: "remote.state.connected.vmNoProxy",
                defaultValue: "Connected to %@ (VM, proxy disabled)"
            ),
            suspendedDetailFormat: String(
                localized: "remote.state.suspended.detail",
                defaultValue: "Can't reach %@ — automatic reconnect is paused. Use Reconnect when your network is back."
            )
        )
    }
}
