import Foundation

struct CloudTunnelStatus: Sendable, Equatable {
    let backend: CloudTunnelBackend
    let state: CloudTunnelState
    /// `cmux vpn up` was run explicitly, so the idle policy keeps the tunnel
    /// up until `cmux vpn down` (or quit / sign-out).
    let isPinned: Bool

    /// Why a private-network route cannot work right now on the app-managed
    /// backend — the line the Machines sidebar shows ahead of a raw link error
    /// — or nil when the tunnel is up. The wg-quick counterpart is
    /// ``VMTunnelManager/privateRouteBlocker()``.
    var privateRouteBlocker: String? {
        switch state {
        case .up:
            return nil
        case .starting, .stopping:
            return String(
                localized: "cloudTree.link.tunnelStarting",
                defaultValue: "This Mac's tunnel to your Cloud VM network is still starting; the machine reconnects on its own."
            )
        case .awaitingApproval:
            return String(
                localized: "cloudTree.link.tunnelAwaitingApproval",
                defaultValue: "macOS is waiting for you to allow the cmux Cloud Tunnel extension in System Settings › General › Login Items & Extensions."
            )
        case .failed(let message):
            let format = String(
                localized: "cloudTree.link.tunnelFailed",
                defaultValue: "This Mac's tunnel to your Cloud VM network could not start: %@"
            )
            return String(format: format, message)
        case .off:
            return String(
                localized: "cloudTree.link.tunnelOffAppManaged",
                defaultValue: "This Mac's tunnel to your Cloud VM network is down; reopen the machine to start it."
            )
        }
    }
}
