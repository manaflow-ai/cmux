public import CMUXMobileCore
import Foundation

/// A ``CmxRouteAwareByteTransportFactory`` that builds WebSocket byte transports.
public struct CmxWebSocketByteTransportFactory: CmxRouteAwareByteTransportFactory {
    /// The route kinds this factory can build a transport for.
    public let supportedKinds: [CmxAttachTransportKind]

    /// Creates a factory for WebSocket routes.
    /// - Parameter supportedKinds: Route kinds this factory accepts. Defaults to `websocket`.
    public init(supportedKinds: [CmxAttachTransportKind] = [.websocket]) {
        self.supportedKinds = supportedKinds
    }

    /// Builds a connected-on-demand transport for a supported WebSocket URL route.
    /// - Parameter route: The attach route to build a transport for.
    /// - Returns: A ``CmxWebSocketByteTransport`` for the route's URL.
    /// - Throws: ``CmxWebSocketByteTransportError`` when the route kind, endpoint, or URL is invalid.
    public func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        try route.validate()
        guard supportedKinds.contains(route.kind) else {
            throw CmxWebSocketByteTransportError.unsupportedRouteKind(route.kind)
        }
        guard case let .url(urlString) = route.endpoint else {
            throw CmxWebSocketByteTransportError.unsupportedEndpoint(route.endpoint)
        }
        return try CmxWebSocketByteTransport(urlString: urlString)
    }
}
