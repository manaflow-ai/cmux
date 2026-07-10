public import CMUXMobileCore

/// Builds Iroh control-lane byte transports for the existing mobile RPC layer.
public struct CmxIrohByteTransportFactory: CmxRouteAwareByteTransportFactory {
    /// The route kind served by this factory.
    public let supportedKinds: [CmxAttachTransportKind] = [.iroh]

    private let supervisor: CmxIrohEndpointSupervisor
    private let contextProvider: any CmxIrohClientContextProvider

    /// Creates an Iroh transport factory.
    ///
    /// - Parameters:
    ///   - supervisor: The app-lifecycle endpoint owner.
    ///   - contextProvider: The authenticated registry and local-policy seam.
    public init(
        supervisor: CmxIrohEndpointSupervisor,
        contextProvider: any CmxIrohClientContextProvider
    ) {
        self.supervisor = supervisor
        self.contextProvider = contextProvider
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
        return CmxIrohByteTransport(
            request: request,
            supervisor: supervisor,
            contextProvider: contextProvider
        )
    }
}
