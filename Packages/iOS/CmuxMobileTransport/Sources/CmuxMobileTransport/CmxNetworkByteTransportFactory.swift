public import CMUXMobileCore

/// Builds the one route-neutral Network.framework transport used by mobile.
///
/// Legacy attach records are normalized before this factory sees them. The
/// factory intentionally has no Tailscale authority, Iroh broker, relay, or
/// path-discovery dependency, so there is exactly one admission point and one
/// lifecycle owner for a Mac connection.
public struct CmxNetworkByteTransportFactory: CmxRouteAwareByteTransportFactory {
    public let supportedKinds: [CmxAttachTransportKind]
    public let maximumReceiveLength: Int
    public let maximumBufferedReceiveBytes: Int
    public var connectTimeoutNanoseconds: UInt64

    public init(
        supportedKinds: [CmxAttachTransportKind] = [.tcp, .debugLoopback],
        maximumReceiveLength: Int = CmxNetworkByteTransport.defaultMaximumReceiveLength,
        maximumBufferedReceiveBytes: Int = CmxNetworkByteTransport.defaultMaximumBufferedReceiveBytes,
        connectTimeoutNanoseconds: UInt64 = CmxNetworkByteTransport.defaultConnectTimeoutNanoseconds
    ) {
        self.supportedKinds = supportedKinds
        self.maximumReceiveLength = maximumReceiveLength
        self.maximumBufferedReceiveBytes = maximumBufferedReceiveBytes
        self.connectTimeoutNanoseconds = max(1, connectTimeoutNanoseconds)
    }

    public func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        try makeTransport(
            for: CmxByteTransportRequest(
                route: route,
                expectedPeerDeviceID: nil,
                authorizationMode: .stackBearer
            )
        )
    }

    public func makeTransport(
        for request: CmxByteTransportRequest
    ) throws -> any CmxByteTransport {
        let route: CmxAttachRoute
        do {
            route = try request.route.normalizedForStableTransport()
        } catch CmxStableTransportRouteError.nativeTransportUnavailable(let kind) {
            throw CmxNetworkByteTransportError.unsupportedRouteKind(kind)
        } catch CmxStableTransportRouteError.endpointUnavailable(let endpoint) {
            throw CmxNetworkByteTransportError.unsupportedEndpoint(endpoint)
        }
        guard supportedKinds.contains(route.kind) else {
            throw CmxNetworkByteTransportError.unsupportedRouteKind(route.kind)
        }
        guard route.kind == .tcp || route.kind == .debugLoopback else {
            throw CmxNetworkByteTransportError.unsupportedRouteKind(route.kind)
        }
        guard case let .hostPort(host, port) = route.endpoint else {
            throw CmxNetworkByteTransportError.unsupportedEndpoint(route.endpoint)
        }
        guard request.authorizationMode == .stackBearer
                || request.authorizationMode == .transportAdmission
                || request.authorizationMode.isLegacyCompatibilityMode else {
            throw CmxNetworkByteTransportError.unsupportedAuthorizationMode(
                request.authorizationMode
            )
        }
        if route.kind == .debugLoopback, !CmxLoopbackHost().matches(route) {
            throw CmxNetworkByteTransportError.unsupportedEndpoint(route.endpoint)
        }
        return try CmxNetworkByteTransport(
            host: host,
            port: port,
            maximumReceiveLength: maximumReceiveLength,
            maximumBufferedReceiveBytes: maximumBufferedReceiveBytes,
            connectTimeoutNanoseconds: connectTimeoutNanoseconds
        )
    }
}

private extension CmxTransportAuthorizationMode {
    var isLegacyCompatibilityMode: Bool {
        switch self {
        case .legacyTailscaleBearer, .userAuthorizedTailscalePairing:
            return true
        case .stackBearer, .transportAdmission:
            return false
        }
    }
}
