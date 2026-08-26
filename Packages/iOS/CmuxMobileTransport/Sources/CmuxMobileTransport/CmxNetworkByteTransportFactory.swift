public import CMUXMobileCore

/// Builds Network.framework TCP transports for host/port routes.
public struct CmxNetworkByteTransportFactory: CmxRouteAwareByteTransportFactory {
    public var supportedKinds: [CmxAttachTransportKind]
    public var maximumReceiveLength: Int
    public var connectTimeoutNanoseconds: UInt64
    private let tailscaleRouteAuthority: any CmxTailscaleRouteAuthorizing

    public init(
        supportedKinds: [CmxAttachTransportKind] = [.tailscale, .debugLoopback],
        maximumReceiveLength: Int = CmxNetworkByteTransport.defaultMaximumReceiveLength,
        connectTimeoutNanoseconds: UInt64 = CmxNetworkByteTransport.defaultConnectTimeoutNanoseconds
    ) {
        self.supportedKinds = supportedKinds
        self.maximumReceiveLength = maximumReceiveLength
        self.connectTimeoutNanoseconds = max(1, connectTimeoutNanoseconds)
        tailscaleRouteAuthority = CmxSystemTailscaleRouteAuthority()
    }

    init(
        supportedKinds: [CmxAttachTransportKind] = [.tailscale, .debugLoopback],
        maximumReceiveLength: Int = CmxNetworkByteTransport.defaultMaximumReceiveLength,
        connectTimeoutNanoseconds: UInt64 = CmxNetworkByteTransport.defaultConnectTimeoutNanoseconds,
        tailscaleRouteAuthority: any CmxTailscaleRouteAuthorizing
    ) {
        self.supportedKinds = supportedKinds
        self.maximumReceiveLength = maximumReceiveLength
        self.connectTimeoutNanoseconds = max(1, connectTimeoutNanoseconds)
        self.tailscaleRouteAuthority = tailscaleRouteAuthority
    }

    public func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        try route.validate()
        guard supportedKinds.contains(route.kind) else {
            throw CmxNetworkByteTransportError.unsupportedRouteKind(route.kind)
        }
        guard case let .hostPort(host, port) = route.endpoint else {
            throw CmxNetworkByteTransportError.unsupportedEndpoint(route.endpoint)
        }
        guard route.kind != .tailscale else {
            throw CmxNetworkByteTransportError.authorizationIntentRequired
        }
        return try CmxNetworkByteTransport(
            host: host,
            port: port,
            maximumReceiveLength: maximumReceiveLength,
            connectTimeoutNanoseconds: connectTimeoutNanoseconds
        )
    }

    /// Preserves authorization intent so generic plaintext Tailscale routes
    /// fail closed and only an exact persisted compatibility grant can dial.
    public func makeTransport(
        for request: CmxByteTransportRequest
    ) throws -> any CmxByteTransport {
        let route = request.route
        try route.validate()
        guard supportedKinds.contains(route.kind) else {
            throw CmxNetworkByteTransportError.unsupportedRouteKind(route.kind)
        }
        guard case let .hostPort(host, port) = route.endpoint else {
            throw CmxNetworkByteTransportError.unsupportedEndpoint(route.endpoint)
        }
        switch route.kind {
        case .tailscale:
            switch request.authorizationMode {
            case let .legacyTailscaleBearer(evidence):
                guard evidence.authorizes(
                    macDeviceID: request.expectedPeerDeviceID,
                    host: host,
                    port: port
                ) else {
                    throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
                }
            case let .userAuthorizedTailscalePairing(authorization):
                // Anchored on the exact user-entered destination; any claimed
                // device identity is self-reported and grants nothing extra.
                guard authorization.authorizes(host: host, port: port) else {
                    throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
                }
            case .stackBearer:
                // A generic Stack bearer never opts into the legacy risk.
                throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
            }
            return CmxPreparingTailscaleByteTransport(
                request: request,
                tailscaleRouteAuthority: tailscaleRouteAuthority,
                maximumReceiveLength: maximumReceiveLength,
                connectTimeoutNanoseconds: connectTimeoutNanoseconds
            )
        case .debugLoopback:
            guard request.authorizationMode == .stackBearer else {
                throw CmxNetworkByteTransportError.unsupportedAuthorizationMode(
                    request.authorizationMode
                )
            }
            guard CmxLoopbackHost().matches(route) else {
                throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
            }
            return try CmxNetworkByteTransport(
                host: host,
                port: port,
                maximumReceiveLength: maximumReceiveLength,
                connectTimeoutNanoseconds: connectTimeoutNanoseconds
            )
        case .websocket:
            throw CmxNetworkByteTransportError.unsupportedRouteKind(route.kind)
        }
    }
}
