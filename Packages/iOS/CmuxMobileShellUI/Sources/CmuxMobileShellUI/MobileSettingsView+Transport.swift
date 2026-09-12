#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport

extension MobileSettingsView {
    func transportName(_ kind: CmxAttachTransportKind) -> String {
        switch kind {
        case .tailscale:
            L10n.string(
                "mobile.settings.activeTransport.tailscale",
                defaultValue: "Tailscale"
            )
        case .iroh:
            L10n.string(
                "mobile.settings.activeTransport.iroh",
                defaultValue: "Iroh"
            )
        case .websocket:
            L10n.string(
                "mobile.settings.activeTransport.websocket",
                defaultValue: "WebSocket"
            )
        case .debugLoopback:
            L10n.string(
                "mobile.settings.activeTransport.simulator",
                defaultValue: "Simulator"
            )
        case .nextTransport:
            L10n.string(
                "mobile.settings.activeTransport.nextTransport",
                defaultValue: "Next transport"
            )
        }
    }

}
#endif
