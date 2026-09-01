import CMUXMobileCore

/// Pure route projections used by the Network.framework byte transport.
struct CmxNetworkByteTransportPath: Sendable {
    func path(
        for kind: CmxAttachTransportKind,
        host: String
    ) -> CmxTransportPath {
        switch kind {
        case .lan: .lan(address: host)
        case .debugLoopback: .debugLoopback
        case .tailscale: .tailscale(address: host)
        case .iroh: .unavailable
        case .websocket: .websocket
        }
    }

    func host(from route: CmxAttachRoute) -> String? {
        guard case let .hostPort(host, _) = route.endpoint else { return nil }
        return host
    }
}
