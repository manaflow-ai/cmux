import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation

extension MobileConnectionMethod {
    /// User-facing name of the connection method.
    var mobileConnectionMethodName: String {
        switch self {
        case .tailscale:
            L10n.string("mobile.connections.method.tailscale", defaultValue: "Tailscale")
        }
    }

    /// The route kind this method dials.
    var routeKind: CmxAttachTransportKind? {
        switch self {
        case .tailscale: .tailscale
        }
    }
}

extension CmxAttachTransportKind {
    /// User-facing name of a route's transport, shared by the per-Computer
    /// route diagnostics.
    var mobileConnectionMethodName: String {
        switch self {
        case .tailscale:
            L10n.string("mobile.connections.method.tailscale", defaultValue: "Tailscale")
        case .websocket:
            L10n.string("mobile.connections.method.websocket", defaultValue: "WebSocket")
        case .debugLoopback:
            L10n.string("mobile.connections.method.debug", defaultValue: "Debug")
        }
    }
}
