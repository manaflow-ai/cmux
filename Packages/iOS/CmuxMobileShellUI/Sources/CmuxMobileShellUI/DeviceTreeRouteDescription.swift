import CMUXMobileCore

/// The reachable endpoint (host:port) the phone would dial for a Connections row.
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

    /// The endpoint shown on a row inside one route-kind section: the first
    /// route of that kind (routes arrive priority-ordered), rendered in its
    /// natural shape (host:port, a truncated peer identity, or a URL).
    static func deviceTreeRouteDescription(
        for routes: [CmxAttachRoute],
        kind: CmxAttachTransportKind
    ) -> String? {
        routes.lazy
            .filter { $0.kind == kind }
            .compactMap { $0.endpoint.deviceTreeEndpointDescription }
            .first
    }
}

extension CmxAttachEndpoint {
    /// A one-line diagnostic rendering of this endpoint for list rows.
    var deviceTreeEndpointDescription: String? {
        switch self {
        case let .hostPort(host, port):
            return "\(host):\(port)"
        case let .peer(identity, _):
            // Peer identities are long hashes; the leading bytes are enough to
            // tell two Macs apart in a diagnostic line.
            let id = identity.endpointID
            return id.count > 12 ? "\(id.prefix(12))…" : id
        case let .url(url):
            return url
        }
    }
}
