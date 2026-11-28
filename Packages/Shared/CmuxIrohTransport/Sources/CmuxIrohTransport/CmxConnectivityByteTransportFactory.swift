public import CMUXMobileCore

/// Route-aware control transport factory backed by one connectivity engine.
public struct CmxConnectivityByteTransportFactory: CmxRouteAwareByteTransportFactory {
    /// The sole route kind served by connectivity v2.
    public let supportedKinds: [CmxAttachTransportKind] = [.iroh]

    private let engine: CmxConnectivityEngine

    /// Creates a stable factory for one process engine.
    public init(engine: CmxConnectivityEngine) {
        self.engine = engine
    }

    /// Creates a disconnected control transport for an exact admitted peer.
    public func makeTransport(
        for request: CmxByteTransportRequest
    ) throws -> any CmxByteTransport {
        try request.route.validate()
        guard request.route.kind == .iroh else {
            throw CmxIrohByteTransportError.unsupportedRouteKind(request.route.kind)
        }
        _ = try CmxConnectivityPeerID(request: request)
        return CmxConnectivityByteTransport(request: request, engine: engine)
    }

    /// Peer intent is mandatory for connectivity-v2 transports.
    public func makeTransport(
        for route: CmxAttachRoute
    ) throws -> any CmxByteTransport {
        try route.validate()
        guard route.kind == .iroh else {
            throw CmxIrohByteTransportError.unsupportedRouteKind(route.kind)
        }
        throw CmxIrohByteTransportError.missingPeerIntent
    }
}
