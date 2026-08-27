public import CMUXMobileCore

/// Stable route-factory facade installed before account activation completes.
///
/// The facade has no endpoint, dial, pooling, or session state. Every
/// connected transport resolves into the process-owned connectivity engine.
public struct CmxConnectivityDeferredTransportFactory:
    CmxRouteAwareByteTransportFactory
{
    public let supportedKinds: [CmxAttachTransportKind] = [.iroh]

    private let provider: any CmxIrohDeferredTransportProviding

    public init(provider: any CmxIrohDeferredTransportProviding) {
        self.provider = provider
    }

    public func makeTransport(
        for route: CmxAttachRoute
    ) throws -> any CmxByteTransport {
        try validatePeerRoute(route)
        throw CmxIrohByteTransportError.missingPeerIntent
    }

    public func makeTransport(
        for request: CmxByteTransportRequest
    ) throws -> any CmxByteTransport {
        let route = request.route
        try validatePeerRoute(route)
        guard request.authorizationMode == .transportAdmission,
              request.expectedPeerDeviceID?.isEmpty == false else {
            throw CmxIrohByteTransportError.missingPeerIntent
        }
        return CmxIrohDeferredByteTransport(
            request: request,
            provider: provider
        )
    }

    private func validatePeerRoute(_ route: CmxAttachRoute) throws {
        try route.validate()
        guard route.kind == .iroh else {
            throw CmxIrohByteTransportError.unsupportedRouteKind(route.kind)
        }
        guard case .peer = route.endpoint else {
            throw CmxIrohByteTransportError.unsupportedEndpoint(route.endpoint)
        }
    }
}
