import Foundation

extension CloudTunnelStatus {
    /// The tunnel's name as Settings, the CLI and MCP title it.
    public static var title: String {
        String(localized: "cloudTunnel.title", defaultValue: "Cloud Tunnel", bundle: .module)
    }

    /// One sentence for the person: what this status means for other apps on the Mac.
    public var summary: String {
        switch self {
        case .off:
            String(localized: "cloudTunnel.describe.off",
                   defaultValue: "Off. Other apps on this Mac cannot reach your Cloud machines.", bundle: .module)
        case .unavailable(let reason), .failed(let reason):
            reason
        case .awaitingApproval:
            String(localized: "cloudTunnel.describe.awaitingApproval",
                   defaultValue: "Allow the cmux network extension in System Settings > General > Login Items & Extensions. The tunnel starts right after.",
                   bundle: .module)
        case .connecting:
            String(localized: "cloudTunnel.describe.connecting", defaultValue: "Connecting…", bundle: .module)
        case .connected:
            String(localized: "cloudTunnel.describe.connected",
                   defaultValue: "On. Every app on this Mac can reach your Cloud machines' private addresses.", bundle: .module)
        case .disconnecting:
            String(localized: "cloudTunnel.describe.disconnecting", defaultValue: "Turning off…", bundle: .module)
        }
    }

    /// Whether a turn-on (`turningOn`) or turn-off ends here, or waits for the person.
    public func settles(turningOn: Bool) -> Bool {
        switch self {
        case .awaitingApproval, .connected: turningOn
        case .off: !turningOn
        case .failed, .unavailable: true
        case .connecting, .disconnecting: false
        }
    }
}

extension CloudTunnelStatus {
    /// Why an agent or another client cannot turn the tunnel on.
    public static var agentRefusal: String {
        String(localized: "cloudTunnel.error.agentRefused",
               defaultValue: "Only you can turn on the Cloud Tunnel: use Settings or `cmux cloud tunnel on` in a terminal.",
               bundle: .module)
    }
}

extension CloudTunnelStatus {
    /// When the tunnel came up, in seconds since 1970, for the CLI's `connected_since`; else `nil`.
    public var connectedSinceSeconds: Int? {
        if case .connected(let since?) = self { Int(since.timeIntervalSince1970) } else { nil }
    }
}
