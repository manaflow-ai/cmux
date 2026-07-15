public import CMUXMobileCore

/// Builds Iroh control-lane byte transports for the existing mobile RPC layer.
public struct CmxIrohByteTransportFactory: CmxRouteAwareByteTransportFactory {
    /// The route kind served by this factory.
    public let supportedKinds: [CmxAttachTransportKind] = [.iroh]

    private let buildTransport: @Sendable (
        _ request: CmxByteTransportRequest
    ) -> any CmxByteTransport

    /// Creates an Iroh transport factory.
    ///
    /// - Parameters:
    ///   - supervisor: The app-lifecycle endpoint owner.
    ///   - contextProvider: The authenticated registry and local-policy seam.
    public init(
        supervisor: CmxIrohEndpointSupervisor,
        contextProvider: any CmxIrohClientContextProvider
    ) {
        buildTransport = { request in
            CmxIrohByteTransport(
                request: request,
                supervisor: supervisor,
                contextProvider: contextProvider
            )
        }
    }

    /// Creates a factory that waits for account-scoped runtime activation on connect.
    ///
    /// - Parameter deferredProvider: The process-owned runtime composition seam.
    public init(deferredProvider: any CmxIrohDeferredTransportProviding) {
        buildTransport = { request in
            CmxIrohDeferredByteTransport(
                request: request,
                provider: deferredProvider
            )
        }
    }

    init(sessionPool: CmxIrohClientSessionPool) {
        buildTransport = { request in
            CmxIrohPooledByteTransport(request: request, pool: sessionPool)
        }
    }

    /// Creates a disconnected control-lane adapter for an Iroh peer route.
    ///
    /// - Parameter route: A validated route whose endpoint is `.peer`.
    /// - Returns: A transport that resolves fresh grants and hints on `connect()`.
    /// - Throws: ``CmxIrohByteTransportError`` for a route-shape mismatch.
    public func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        try route.validate()
        guard route.kind == .iroh else {
            throw CmxIrohByteTransportError.unsupportedRouteKind(route.kind)
        }
        guard case .peer = route.endpoint else {
            throw CmxIrohByteTransportError.unsupportedEndpoint(route.endpoint)
        }
        throw CmxIrohByteTransportError.missingPeerIntent
    }

    /// Creates a disconnected transport bound to the intended Mac device.
    public func makeTransport(
        for request: CmxByteTransportRequest
    ) throws -> any CmxByteTransport {
        let route = request.route
        try route.validate()
        guard route.kind == .iroh else {
            throw CmxIrohByteTransportError.unsupportedRouteKind(route.kind)
        }
        guard case .peer = route.endpoint else {
            throw CmxIrohByteTransportError.unsupportedEndpoint(route.endpoint)
        }
        guard request.authorizationMode == .transportAdmission,
              request.expectedPeerDeviceID?.isEmpty == false else {
            throw CmxIrohByteTransportError.missingPeerIntent
        }
        return buildTransport(request)
    }
}
