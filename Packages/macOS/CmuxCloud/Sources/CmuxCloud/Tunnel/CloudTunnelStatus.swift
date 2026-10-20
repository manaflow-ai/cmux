import CmuxCloudBannerCore
import Foundation

public struct CloudTunnelStatus: Sendable, Equatable {
    public init(
        backend: CloudTunnelBackend,
        state: CloudTunnelState,
        isPinned: Bool
    ) {
        self.backend = backend
        self.state = state
        self.isPinned = isPinned
    }

    public let backend: CloudTunnelBackend
    public let state: CloudTunnelState
    /// `cmux vpn up` was run explicitly, so the idle policy keeps the tunnel
    /// up until `cmux vpn down` (or quit / sign-out).
    public let isPinned: Bool

    /// What is standing between an explicit `cmux vpn up` and a working
    /// system-wide route, or nil when there is nothing to report: the tunnel
    /// is up, or it is off. Off blocks nothing in the app, because Ports,
    /// Desktop, and terminals reach machines over the user-space hub; the
    /// Machines panel shows this text while a start is in flight.
    public var privateRouteBlocker: String? {
        switch state {
        case .up, .off:
            return nil
        case .starting:
            return String(
                localized: "cloudTree.link.tunnelStarting",
                defaultValue: "The cmux Cloud Tunnel is starting…"
            )
        case .stopping:
            return String(
                localized: "cloudTree.link.tunnelStopping",
                defaultValue: "The cmux Cloud Tunnel is stopping…"
            )
        case .awaitingApproval:
            return String(
                localized: "cloudTree.link.tunnelAwaitingApproval",
                defaultValue: "macOS is waiting for you to allow the cmux Cloud Tunnel extension in System Settings › General › Login Items & Extensions."
            )
        case .failed(let message):
            let format = String(
                localized: "cloudTree.link.tunnelFailed",
                defaultValue: "The cmux Cloud Tunnel could not start: %@"
            )
            return String(format: format, message)
        }
    }
}
