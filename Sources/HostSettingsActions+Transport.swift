import CMUXMobileCore
import Foundation

extension HostSettingsActions {
    /// Localized transport label for a pairing route shown in diagnostics.
    nonisolated static func routeKindLabel(_ kind: CmxAttachTransportKind) -> String {
        switch kind {
        case .tailscale:
            return String(localized: "settings.mobile.route.tailscale", defaultValue: "Tailscale")
        case .debugLoopback:
            return String(localized: "settings.mobile.route.loopback", defaultValue: "Loopback")
        case .iroh:
            return String(localized: "settings.mobile.route.iroh", defaultValue: "Iroh")
        case .websocket:
            return String(localized: "settings.mobile.route.websocket", defaultValue: "WebSocket")
        case .nextTransport:
            return String(
                localized: "settings.mobile.route.nextTransport",
                defaultValue: "Next transport"
            )
        }
    }

}
