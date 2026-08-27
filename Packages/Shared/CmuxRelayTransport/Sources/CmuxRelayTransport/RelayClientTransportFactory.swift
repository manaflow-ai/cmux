// Factory for the `.websocket` route kind. Registered alongside the other
// per-kind factories in the app composition roots; the route's URL is the
// authorized dial target and `expectedPeerDeviceID` names the host whose
// relay object we mint a ticket for.

import CMUXMobileCore
import Foundation

public struct RelayClientTransportFactory: CmxRouteAwareByteTransportFactory {
    public let supportedKinds: [CmxAttachTransportKind] = [.websocket]

    private let deviceID: @Sendable () async throws -> String
    private let ticketProvider: any RelayTicketProviding
    private let makeConnection: RelayConnectionFactory

    public init(
        deviceID: @escaping @Sendable () async throws -> String,
        ticketProvider: any RelayTicketProviding,
        makeConnection: @escaping RelayConnectionFactory = RelayConnection.factory()
    ) {
        self.deviceID = deviceID
        self.ticketProvider = ticketProvider
        self.makeConnection = makeConnection
    }

    public func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        // A relay dial without peer intent could mint a ticket for a host the
        // caller never authorized; require the full request.
        throw RelayTransportError.invalidRequest("relay routes require a peer-bound transport request")
    }

    public func makeTransport(for request: CmxByteTransportRequest) throws -> any CmxByteTransport {
        guard request.route.kind == .websocket else {
            throw RelayTransportError.invalidRequest("unsupported route kind")
        }
        // The route endpoint is nominal (routes require one); the actual dial
        // target is the URL the ticket mint returns, so the server controls
        // the relay endpoint per environment. Still reject a malformed route.
        guard case .url(let raw) = request.route.endpoint,
              let url = URL(string: raw),
              url.scheme == "wss" || url.scheme == "ws" else {
            throw RelayTransportError.invalidRequest("relay route needs a ws(s) URL endpoint")
        }
        _ = url
        guard let hostDeviceID = request.expectedPeerDeviceID, !hostDeviceID.isEmpty else {
            throw RelayTransportError.invalidRequest("relay route needs the host device id")
        }
        return RelayClientByteTransport(
            hostDeviceID: hostDeviceID,
            deviceID: deviceID,
            ticketProvider: ticketProvider,
            makeConnection: makeConnection
        )
    }
}
