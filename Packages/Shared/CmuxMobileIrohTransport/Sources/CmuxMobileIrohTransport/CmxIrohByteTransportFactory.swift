public import CMUXMobileCore

/// A ``CmxRouteAwareByteTransportFactory`` that builds ``CmxIrohByteTransport``
/// instances for `.iroh` peer routes.
public struct CmxIrohByteTransportFactory: CmxRouteAwareByteTransportFactory {
    public let supportedKinds: [CmxAttachTransportKind] = [.iroh]

    /// The phone's iroh secret key. When nil, each transport binds with a fresh
    /// ephemeral key; full PR 3 supplies the stable Keychain key so the phone
    /// keeps one EndpointId.
    private let secretKey: [UInt8]?
    private let relayAuthToken: String?
    private let relayOnly: Bool
    private let maximumReceiveLength: Int

    /// Creates a factory for iroh route transports.
    /// - Parameters:
    ///   - secretKey: The phone's stable iroh secret key, or nil for ephemeral keys.
    ///   - relayAuthToken: An optional bind-time custom relay auth token.
    ///   - relayOnly: Whether transports disable local IP paths.
    ///   - maximumReceiveLength: The maximum bytes returned by one receive.
    public init(
        secretKey: [UInt8]? = nil,
        relayAuthToken: String? = nil,
        relayOnly: Bool = false,
        maximumReceiveLength: Int = CmxIrohByteTransport.defaultMaximumReceiveLength
    ) {
        self.secretKey = secretKey
        self.relayAuthToken = relayAuthToken
        self.relayOnly = relayOnly
        self.maximumReceiveLength = maximumReceiveLength
    }

    public func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        guard supportedKinds.contains(route.kind) else {
            throw CmxIrohByteTransportError.unsupportedRouteKind(route.kind)
        }
        return try CmxIrohByteTransport(
            route: route,
            relayAuthToken: relayAuthToken,
            secretKey: secretKey,
            relayOnly: relayOnly,
            maximumReceiveLength: maximumReceiveLength
        )
    }
}
