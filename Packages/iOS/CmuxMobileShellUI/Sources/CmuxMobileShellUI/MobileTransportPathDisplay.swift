import CMUXMobileCore
import CmuxMobileSupport

/// Localized rendering for the concrete path shown in connection chrome.
extension CmxTransportPath {
    var mobileStatusDisplayValue: String? {
        switch self {
        case .unavailable:
            return nil
        case let .lan(address):
            return String(format: L10n.string(
                "mobile.settings.activeTransport.lanFormat",
                defaultValue: "LAN · %@"
            ), address)
        case let .tailscale(address):
            return String(format: L10n.string(
                "mobile.settings.activeTransport.tailscaleFormat",
                defaultValue: "Tailscale · %@"
            ), address)
        case .irohDirect:
            return L10n.string(
                "mobile.settings.activeTransport.irohDirect",
                defaultValue: "iroh direct"
            )
        case let .irohRelay(region):
            guard let region, !region.isEmpty else {
                return L10n.string(
                    "mobile.settings.activeTransport.irohRelay",
                    defaultValue: "iroh relay"
                )
            }
            return String(format: L10n.string(
                "mobile.settings.activeTransport.irohRelayFormat",
                defaultValue: "iroh relay %@"
            ), region)
        case .websocket:
            return L10n.string(
                "mobile.settings.activeTransport.websocket",
                defaultValue: "WebSocket"
            )
        case .debugLoopback:
            return L10n.string(
                "mobile.settings.activeTransport.simulator",
                defaultValue: "Simulator"
            )
        }
    }
}
