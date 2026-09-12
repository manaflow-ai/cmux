import Foundation

extension DiagnosticEventPresentation {
    /// Human-readable name of a transport category.
    public func displayName(_ kind: DiagnosticTransportKind) -> String {
        switch kind {
        case .unknown: localized("diagnostics.transport.unknown", defaultValue: "Unknown transport")
        case .iroh: localized("diagnostics.transport.iroh", defaultValue: "Iroh")
        case .tailscale: localized("diagnostics.transport.tailscale", defaultValue: "Tailscale")
        case .websocket: localized("diagnostics.transport.websocket", defaultValue: "WebSocket")
        case .debugLoopback: localized("diagnostics.transport.debugLoopback", defaultValue: "Debug loopback")
        case .nextTransport: localized("diagnostics.transport.nextTransport", defaultValue: "Next transport")
        }
    }

}
