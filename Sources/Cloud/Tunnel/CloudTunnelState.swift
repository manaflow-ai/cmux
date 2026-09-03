import Foundation

/// The app-managed tunnel's lifecycle as ``CloudTunnelCoordinator`` drives it.
enum CloudTunnelState: Sendable, Equatable {
    /// Down, and nothing is asking for it. The launch state.
    case off
    /// Enrolling, saving the VPN configuration, or waiting for the link.
    case starting
    /// The first activation is blocked on the user allowing the system
    /// extension in System Settings. Resolves on its own once they do.
    case awaitingApproval
    /// The WireGuard link is connected.
    case up
    case stopping
    /// The last start attempt failed; `message` is user-presentable. The next
    /// Cloud use retries from scratch.
    case failed(String)

    /// Stable token for socket payloads and `cmux vpn status`.
    var wireName: String {
        switch self {
        case .off: return "off"
        case .starting: return "starting"
        case .awaitingApproval: return "awaiting-approval"
        case .up: return "up"
        case .stopping: return "stopping"
        case .failed: return "failed"
        }
    }

    /// True while a start is still in progress (the outcome is not known yet).
    var isSettling: Bool {
        switch self {
        case .starting, .awaitingApproval, .stopping: return true
        case .off, .up, .failed: return false
        }
    }

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// A snapshot for `vm.tunnel_status` and `cmux vpn status`.
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
