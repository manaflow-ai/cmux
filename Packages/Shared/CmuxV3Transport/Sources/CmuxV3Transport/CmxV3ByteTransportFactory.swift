import CMUXMobileCore
import CmuxV3Native
import CryptoKit
import Foundation

/// Supplies server-issued v3 grants for one exact route and operation.
public protocol CmxV3GrantProviding: Sendable {
    /// Resolve the device through the authenticated directory before requesting its grant.
    func authorization(for request: CmxByteTransportRequest, source: String) async throws -> CmxV3Authorization
    /// Request a grant for one exact application lane action.
    func authorization(for request: CmxByteTransportRequest, source: String, action: String) async throws -> CmxV3Authorization
}

public extension CmxV3GrantProviding {
    func authorization(for request: CmxByteTransportRequest, source: String, action: String) async throws -> CmxV3Authorization {
        guard action == "connect" else { throw CmxV3TransportError.actionUnsupported }
        return try await authorization(for: request, source: source)
    }
    func relayGrant(for request: CmxByteTransportRequest, source: String, relay: String) async throws -> String? { nil }
}

public struct CmxV3Authorization: Sendable {
    public let deviceID: String
    public let peerID: String
    public let grant: String
    public let addresses: [String]
    public init(deviceID: String, peerID: String, grant: String, addresses: [String] = []) {
        self.deviceID = deviceID
        self.peerID = peerID
        self.grant = grant
        self.addresses = addresses
    }
}

/// Route-aware v3 factory. The route's peer ID and addresses are hints only;
/// the Rust endpoint authenticates the resulting libp2p identity and grant.
public struct CmxV3ByteTransportFactory: CmxRouteAwareByteTransportFactory {
    public let supportedKinds: [CmxAttachTransportKind] = [.v3]
    private let endpoint: NativeEndpoint
    private let grants: any CmxV3GrantProviding

    public init(endpoint: NativeEndpoint, grants: any CmxV3GrantProviding) {
        self.endpoint = endpoint
        self.grants = grants
    }

    public func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        throw CmxV3TransportError.peerIntentRequired
    }

    public func makeTransport(for request: CmxByteTransportRequest) throws -> any CmxByteTransport {
        try makeLaneTransport(for: request, kind: 0, resource: nil, cursor: nil)
    }

    /// Builds one independently authorized session lane. `kind` uses the
    /// shared v3 lane table: 0 control, 1 events, 2 terminal read, 3 terminal
    /// input, 4 artifact, 5 simulator.
    public func makeLaneTransport(
        for request: CmxByteTransportRequest,
        kind: UInt8,
        resource: String? = nil,
        cursor: UInt64? = nil
    ) throws -> any CmxByteTransport {
        try request.route.validate()
        guard request.route.kind == .v3 else { throw CmxV3TransportError.unsupportedRoute }
        guard case let .v3Peer(identity) = request.route.endpoint,
              request.authorizationMode == .transportAdmission,
              !identity.addresses.isEmpty,
              kind <= 5
        else { throw CmxV3TransportError.peerIntentRequired }
        let endpoint = self.endpoint
        let grants = self.grants
        return V3ByteTransport { operation in
            let action = switch kind {
            case 2: "terminal_read"
            case 3: "terminal_write"
            default: "connect"
            }
            let authorization = try await grants.authorization(for: request, source: endpoint.peerId(), action: action)
            if let expected = request.expectedPeerDeviceID, authorization.deviceID != expected {
                throw CmxV3TransportError.peerIntentRequired
            }
            guard authorization.peerID == identity.peerID else {
                throw CmxV3TransportError.peerIntentRequired
            }
            var lastError: any Error = CmxV3TransportError.unsupportedRoute
            for address in identity.addresses {
                try Task.checkCancellation()
                do {
                    let relayGrant: String? = if let relay = address.relayPeerID {
                        try await grants.relayGrant(for: request, source: endpoint.peerId(), relay: relay)
                    } else { nil }
                    return try await endpoint.open(peerId: identity.peerID, address: address,
                        grant: authorization.grant, relayGrant: relayGrant,
                        lane: LaneDescriptor(kind: kind, resource: resource, cursor: cursor), operation: operation)
                } catch NativeError.Transport {
                    lastError = NativeError.Transport
                }
            }
            throw lastError
        }
    }

}

private extension String {
    var relayPeerID: String? {
        let parts = split(separator: "/")
        guard let circuit = parts.firstIndex(of: "p2p-circuit"), circuit >= 2,
              parts[circuit - 2] == "p2p" else { return nil }
        return String(parts[circuit - 1])
    }
}

public enum CmxV3TransportError: Error, Equatable, Sendable {
    case unsupportedRoute
    case peerIntentRequired
    case actionUnsupported
}
