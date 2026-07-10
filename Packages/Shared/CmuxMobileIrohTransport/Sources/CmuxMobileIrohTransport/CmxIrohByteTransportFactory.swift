public import CMUXMobileCore

/// A ``CmxRouteAwareByteTransportFactory`` that builds ``CmxIrohByteTransport``
/// instances for `.iroh` peer routes.
public struct CmxIrohByteTransportFactory: CmxRouteAwareByteTransportFactory {
    public let supportedKinds: [CmxAttachTransportKind] = [.iroh]

    /// The phone's iroh secret key. When nil, each transport binds with a fresh
    /// ephemeral key; full PR 3 supplies the stable Keychain key so the phone
    /// keeps one EndpointId.
    private let secretKey: [UInt8]?
    private let relayOnly: Bool
    private let maximumReceiveLength: Int

    public init(
        secretKey: [UInt8]? = nil,
        relayOnly: Bool = false,
        maximumReceiveLength: Int = CmxIrohByteTransport.defaultMaximumReceiveLength
    ) {
        self.secretKey = secretKey
        self.relayOnly = relayOnly
        self.maximumReceiveLength = maximumReceiveLength
    }

    public func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        guard supportedKinds.contains(route.kind) else {
            throw CmxIrohByteTransportError.unsupportedRouteKind(route.kind)
        }
        return try CmxIrohByteTransport(
            route: route,
            secretKey: secretKey,
            relayOnly: relayOnly,
            maximumReceiveLength: maximumReceiveLength
        )
    }
}
