import CMUXMobileCore
import CmuxMobileSupport
import Foundation

extension CmxAttachTransportKind {
    var mobileDisplayLabel: String {
        switch self {
        case .iroh:
            return L10n.string("mobile.connection.transport.iroh", defaultValue: "Iroh")
        case .tailscale:
            return L10n.string("mobile.connection.transport.tailscale", defaultValue: "Tailscale")
        case .debugLoopback:
            return L10n.string("mobile.connection.transport.loopback", defaultValue: "Loopback")
        case .websocket:
            return L10n.string("mobile.connection.transport.websocket", defaultValue: "WebSocket")
        }
    }

    func mobileToolbarSubtitle(terminalName: String?) -> String {
        let label = mobileDisplayLabel
        guard let terminalName,
              !terminalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let format = L10n.string(
                "mobile.connection.transportOnlyFormat",
                defaultValue: "Connected via %@"
            )
            return String(format: format, label)
        }
        let format = L10n.string(
            "mobile.connection.terminalTransportFormat",
            defaultValue: "%@ via %@"
        )
        return String(format: format, terminalName, label)
    }
}
