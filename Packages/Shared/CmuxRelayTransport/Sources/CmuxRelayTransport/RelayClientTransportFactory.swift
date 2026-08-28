// Factory for the `.websocket` route kind. Registered alongside the other
// per-kind factories in the app composition roots; the route's URL is the
// authorized dial target and `expectedPeerDeviceID` names the host whose
// relay object we mint a ticket for.

import CMUXMobileCore
import Foundation

public struct RelayClientTransportFactory: CmxRouteAwareByteTransportFactory {
    public let supportedKinds: [CmxAttachTransportKind] = [.websocket]

    private let deviceID: @Sendable () async throws -> String
    private let accessToken: RelayAccessTokenProvider
    private let makeConnection: RelayConnectionFactory

    public init(
        deviceID: @escaping @Sendable () async throws -> String,
        accessToken: @escaping RelayAccessTokenProvider,
        makeConnection: @escaping RelayConnectionFactory = RelayConnection.factory()
    ) {
        self.deviceID = deviceID
        self.accessToken = accessToken
        self.makeConnection = makeConnection
    }

    public func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        // A relay dial without peer intent could bind a session to a host the
        // caller never authorized; require the full request.
        throw RelayTransportError.invalidRequest("relay routes require a peer-bound transport request")
    }

    public func makeTransport(for request: CmxByteTransportRequest) throws -> any CmxByteTransport {
        guard request.route.kind == .websocket else {
            throw RelayTransportError.invalidRequest("unsupported route kind")
        }
        // The route's URL is the dial target (the synthesized relay route
        // resolves the Debug env override; production is the constant).
        guard case .url(let raw) = request.route.endpoint,
              let url = URL(string: raw),
              url.scheme == "wss" || url.scheme == "ws" else {
            throw RelayTransportError.invalidRequest("relay route needs a ws(s) URL endpoint")
        }
        guard let hostDeviceID = request.expectedPeerDeviceID, !hostDeviceID.isEmpty else {
            throw RelayTransportError.invalidRequest("relay route needs the host device id")
        }
        return RelayClientByteTransport(
            relayURLOverride: url,
            hostDeviceID: hostDeviceID,
            deviceID: deviceID,
            accessToken: accessToken,
            makeConnection: makeConnection
        )
    }
}
