import Foundation

@MainActor
struct CloudPortAccessText {
    static func status(_ phase: CloudPortAccessModel.Phase) -> String {
        switch phase {
        case .needsVPN: return String(localized: "cloud.ports.needsVPN", defaultValue: "VPN not connected")
        case .stopping: return String(localized: "cloud.ports.stopping", defaultValue: "Stopping…")
        case .connecting: return String(localized: "cloud.ports.connecting", defaultValue: "Connecting…")
        case .direct: return String(localized: "cloud.ports.direct", defaultValue: "Private VPN")
        case .forwarded: return String(localized: "cloud.ports.forwarded", defaultValue: "Forwarding")
        case .failed: return String(localized: "cloud.vpn.setup.failed", defaultValue: "Needs attention")
        case .closed: return String(localized: "cloud.ports.closed", defaultValue: "Closed")
        }
    }
}
