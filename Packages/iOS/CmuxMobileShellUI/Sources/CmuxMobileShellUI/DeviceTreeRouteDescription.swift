import CMUXMobileCore

/// The reachable endpoint (host:port) the phone would dial for a Computers row.
extension CmxAttachRoute {
    static func deviceTreeRouteDescription(for routes: [CmxAttachRoute]) -> String? {
        func endpoint(_ route: CmxAttachRoute) -> String? {
            if case let .hostPort(host, port) = route.endpoint { return "\(host):\(port)" }
            return nil
        }
        if let nonLoopback = routes.first(where: { $0.kind != .debugLoopback }),
           let endpoint = endpoint(nonLoopback) {
            return endpoint
        }
        return routes.lazy.compactMap(endpoint).first
    }
}
