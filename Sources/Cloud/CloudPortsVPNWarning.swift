import Foundation

/// The optional system-wide VPN explanation shown beside a Cloud Ports group.
/// The projection is independent of the port forwarder, so showing it cannot
/// change or gate the in-app loopback route.
struct CloudPortsVPNWarning: Equatable, Sendable {
    let title: String
    let help: String

    /// The persisted signature for the stable off-state copy.
    var dismissalSignature: String { "cloud-vpn-off-v1" }

    /// Returns a warning while the macOS system tunnel is not connected.
    static func projection(isVPNConnected: Bool) -> Self? {
        guard !isVPNConnected else { return nil }
        return Self(
            title: String(localized: "cloud.ports.vpnOff.title", defaultValue: "Cloud VPN is off"),
            help: String(
                localized: "cloudTree.tunnel.help",
                defaultValue: "The cmux Cloud Tunnel is a macOS network extension that gives every app on this Mac a route to your Cloud VM network. cmux itself does not need it: terminals, Ports, and Desktop use the built-in user-space tunnel."
            )
        )
    }
}

extension CloudTunnelBanner {
    /// A stable state-and-copy identity for dismissing the Machines banner.
    var dismissalSignature: String {
        String(describing: kind) + "|" + text + "|" + String(opensSystemSettings)
    }
}

extension MachinePlanSnapshot.FreeAccessBanner {
    /// A stable identity that changes when the countdown or lock state changes.
    var dismissalSignature: String {
        switch self {
        case .none: return "none"
        case .expiresIn: return "expires-in"
        case .expiresToday: return "expires-today"
        case .expired: return "expired"
        }
    }
}
