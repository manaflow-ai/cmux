import Foundation
import CmuxCloudBannerCore

/// App-target alias for the package-owned optional VPN warning projection.
typealias CloudPortsVPNWarning = CmuxCloudBannerCore.CloudPortsVPNWarning

extension CloudPortsVPNWarning {
    /// Only a supported, explicitly off system VPN offers setup in the tree.
    static func projection(status: CloudTunnelStatus?) -> Self? {
        guard let status, status.backend.isNetworkExtension else { return nil }
        return projection(tunnelState: status.state)
    }

    var setupTitle: String {
        String(localized: "cloud.ports.vpnOff.configure", defaultValue: "Configure cmux VPN")
    }

    /// Localized title shown beside the Cloud Ports group.
    var title: String {
        String(localized: "cloud.ports.vpnOff.title", defaultValue: "Cloud VPN is off")
    }

    /// Localized explanation of optional system-wide VPN access.
    var help: String {
        "\(setupTitle)\n\(explanation)"
    }

    /// Localized explanation shown in the Ports empty state and hover help.
    var explanation: String {
        String(
            localized: "cloud.ports.vpnOff.explanation",
            defaultValue: "cmux’s in-app forwarding works without a system VPN. Cloud VPN lets Safari, Chrome, and other apps open private VM ports."
        )
    }

    /// Stable state-and-copy identity used by dismissal persistence.
    var dismissalSignature: String { "cloud-vpn-off-v1" }
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
