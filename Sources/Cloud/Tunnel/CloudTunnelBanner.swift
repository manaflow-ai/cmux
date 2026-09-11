import Foundation

/// What the Machines panel says about the explicit system-wide Cloud VPN
/// (`cmux vpn up`) while it is doing anything at all. Nil when the tunnel is
/// off or this build cannot run it: nothing in the panel depends on it, so
/// there is nothing to say.
///
/// Pure projection of ``CloudTunnelStatus`` so the copy and the "open System
/// Settings" affordance are testable without a view.
struct CloudTunnelBanner: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case starting
        case stopping
        /// macOS is waiting for the user to allow the extension; the banner
        /// offers the System Settings pane.
        case awaitingApproval
        case connected
        case failed
    }

    let kind: Kind
    let text: String

    /// Only the approval wait sends the user somewhere.
    var opensSystemSettings: Bool { kind == .awaitingApproval }

    init?(status: CloudTunnelStatus) {
        guard status.backend.isNetworkExtension else { return nil }
        switch status.state {
        case .off:
            return nil
        case .starting:
            kind = .starting
            text = status.privateRouteBlocker ?? ""
        case .stopping:
            kind = .stopping
            text = status.privateRouteBlocker ?? ""
        case .awaitingApproval:
            kind = .awaitingApproval
            text = status.privateRouteBlocker ?? ""
        case .failed:
            kind = .failed
            text = status.privateRouteBlocker ?? ""
        case .up:
            kind = .connected
            text = status.isPinned
                ? String(
                    localized: "cloudTree.tunnel.connectedPinned",
                    defaultValue: "cmux Cloud Tunnel is on: every app on this Mac can reach your Cloud VM network. `cmux vpn down` turns it off."
                )
                : String(
                    localized: "cloudTree.tunnel.connected",
                    defaultValue: "cmux Cloud Tunnel is on: every app on this Mac can reach your Cloud VM network. It stops on its own when idle."
                )
        }
    }
}
