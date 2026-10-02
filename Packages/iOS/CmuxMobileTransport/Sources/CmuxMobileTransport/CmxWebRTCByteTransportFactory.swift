public import CMUXMobileCore
import Foundation

/// Builds experimental WebRTC transports for `webrtc://` attach routes.
public struct CmxWebRTCByteTransportFactory: CmxRouteAwareByteTransportFactory {
    /// The only route kind this factory accepts.
    public let supportedKinds: [CmxAttachTransportKind] = [.webrtc]
    /// ICE and timeout settings used by created transports.
    public let configuration: CmxWebRTCConfiguration
    /// Optional authenticated provider for short-lived ICE credentials.
    public let iceServersProvider: CmxWebRTCIceServersProvider?
    /// Authenticates the public signaling relay on behalf of the signed-in account.
    public let signalingAccessTokenProvider: CmxWebRTITokenProvider?

    /// Creates a WebRTC transport factory.
    ///
    /// - Parameter configuration: ICE servers and deadlines for new peers.
    public init(
        configuration: CmxWebRTCConfiguration = CmxWebRTCConfiguration(),
        iceServersProvider: CmxWebRTCIceServersProvider? = nil,
        signalingAccessTokenProvider: CmxWebRTITokenProvider? = nil
    ) {
        self.configuration = configuration
        self.iceServersProvider = iceServersProvider
        self.signalingAccessTokenProvider = signalingAccessTokenProvider
    }

    /// Builds a client transport from a route without extra request context.
    ///
    /// - Parameter route: A validated WebRTC route.
    /// - Returns: A transport that will connect when its `connect()` method runs.
    /// - Throws: ``CmxWebRTCByteTransportError`` for an invalid route.
    public func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        try makeTransport(for: CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: nil,
            authorizationMode: .stackBearer
        ))
    }

    /// Builds a client transport while preserving the request's authorization intent.
    ///
    /// WebRTC signaling is only exposed by the experimental host with a Stack
    /// bearer control session. Legacy Tailscale grants and transport-admission
    /// sessions are rejected so a route cannot silently change its trust model.
    ///
    /// - Parameter request: Route and authorization intent for the connection.
    /// - Returns: A client transport bound to exactly that route.
    /// - Throws: ``CmxWebRTCByteTransportError`` for unsupported authority or URL.
    public func makeTransport(
        for request: CmxByteTransportRequest
    ) throws -> any CmxByteTransport {
        try request.route.validate()
        guard request.route.kind == .webrtc else {
            throw CmxWebRTCByteTransportError.invalidRoute
        }
        guard case .stackBearer = request.authorizationMode else {
            throw CmxWebRTCByteTransportError.unsupportedAuthorizationMode(
                request.authorizationMode
            )
        }
        guard case let .url(rawURL) = request.route.endpoint,
              let components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "webrtc",
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else {
            throw CmxWebRTCByteTransportError.invalidRoute
        }
        if components.host?.lowercased() == "relay",
           let relayValue = components.queryItems?.first(where: { $0.name == "relay" })?.value,
           let relayURL = URL(string: relayValue) {
            return try CmxWebRTCByteTransport(
                clientRelayURL: relayURL,
                token: token,
                configuration: configuration,
                iceServersProvider: iceServersProvider,
                signalingAccessTokenProvider: signalingAccessTokenProvider
            )
        }
        guard let host = components.host, let port = components.port else {
            throw CmxWebRTCByteTransportError.invalidRoute
        }
        return try CmxWebRTCByteTransport(
            clientHost: host,
            clientPort: port,
            token: token,
            configuration: configuration,
            iceServersProvider: iceServersProvider,
            signalingAccessTokenProvider: signalingAccessTokenProvider
        )
    }
}
