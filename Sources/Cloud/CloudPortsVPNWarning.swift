import Foundation
import CmuxCloudBannerCore

/// App-target alias for the package-owned optional VPN warning projection.
typealias CloudPortsVPNWarning = CmuxCloudBannerCore.CloudPortsVPNWarning

extension CloudPortsVPNWarning {
    /// Localized title shown beside the Cloud Ports group.
    var title: String {
        String(localized: "cloud.ports.vpnOff.title", defaultValue: "Cloud VPN is off")
    }

    /// Localized explanation of optional system-wide VPN access.
    var help: String {
        String(
            localized: "cloud.vpn.setup.howItWorks.body",
            defaultValue: "Connect Safari, Chrome, and other apps to your Cloud machines. Each machine keeps its private IP address and original ports. Only traffic to your Cloud network uses this encrypted connection. cmux terminals, Ports, and Desktop work without it."
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
