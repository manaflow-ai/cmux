public import CMUXMobileCore
public import Foundation

/// Local failures while constructing endpoint-authenticated registration.
public enum PeerRegistrationError: Error, Equatable, Sendable {
    /// A UUID, tag, display name, generation, capability, or hint is invalid.
    case invalidPayload
    /// The encoded registration exceeds the broker request limit.
    case payloadTooLarge
    /// The endpoint secret does not derive the declared EndpointID.
    case endpointIdentityMismatch
    /// The broker challenge identifier or nonce is malformed.
    case invalidChallenge
}

/// Endpoint-authenticated device state submitted to the trust broker.
///
/// Canonical encoding (sorted keys, ISO 8601 dates) is unchanged from the
/// previous transport; the payload hash and signature cover these exact bytes.
public struct PeerRegistrationPayload: Encodable, Equatable, Sendable {
    /// Route contract understood by this client and its admission provider.
    public static let currentRouteContractVersion = 1

    private enum CodingKeys: String, CodingKey {
        case routeContractVersion = "route_contract_version"
        case deviceID = "deviceId"
        case appInstanceID = "appInstanceId"
        case clientNamespace
        case tag
        case platform
        case displayName
        case endpointID = "endpointId"
        case identityGeneration
        case pairingEnabled
        case capabilities
        case pathHints
        case directPorts
    }

    public let routeContractVersion: Int
    public let deviceID: String
    public let appInstanceID: String
    public let clientNamespace: String
    public let tag: String
    public let platform: PeerPlatform
    public let displayName: String?
    /// Canonical 64-character lowercase EndpointID.
    public let endpointID: String
    public let identityGeneration: Int
    public let pairingEnabled: Bool
    public let capabilities: [String]
    public let pathHints: [CmxIrohPathHint]
    public let directPorts: PeerBrokerDirectPorts?

    /// Creates a payload matching the broker contract.
    public init(
        deviceID: String,
        appInstanceID: String,
        clientNamespace: String = "legacy",
        tag: String,
        platform: PeerPlatform,
        displayName: String? = nil,
        endpointID: String,
        identityGeneration: Int,
        pairingEnabled: Bool,
        capabilities: [String],
        pathHints: [CmxIrohPathHint],
        directPorts: PeerBrokerDirectPorts? = nil,
        now: Date = Date()
    ) throws {
        guard PeerBrokerWire.isBrokerUUID(deviceID),
              PeerBrokerWire.isBrokerUUID(appInstanceID),
              PeerBrokerWire.isSafeClientNamespace(clientNamespace),
              PeerBrokerWire.isSafeToken(tag),
              (try? CmxIrohPeerIdentity(endpointID: endpointID)) != nil,
              (1 ... Int(Int32.max)).contains(identityGeneration),
              capabilities.count <= 32,
              Set(capabilities).count == capabilities.count,
              capabilities.allSatisfy({ PeerBrokerWire.isSafeToken($0) }),
              pathHints.count <= 16,
              pathHints.filter({ $0.kind == .relayURL }).count <= 2,
              pathHints.allSatisfy({ Self.isBrokerHint($0, now: now) }) else {
            throw PeerRegistrationError.invalidPayload
        }
        if let displayName {
            guard PeerBrokerWire.isSafeDisplayName(displayName) else {
                throw PeerRegistrationError.invalidPayload
            }
        }
        routeContractVersion = Self.currentRouteContractVersion
        self.deviceID = cmxCanonicalDeviceID(deviceID)
        self.appInstanceID = appInstanceID.lowercased()
        self.clientNamespace = clientNamespace
        self.tag = tag
        self.platform = platform
        self.displayName = displayName
        self.endpointID = endpointID
        self.identityGeneration = identityGeneration
        self.pairingEnabled = pairingEnabled
        self.capabilities = capabilities
        self.pathHints = pathHints
        self.directPorts = directPorts
    }

    private static func isBrokerHint(_ hint: CmxIrohPathHint, now: Date) -> Bool {
        guard hint.kind != .relayIdentifier,
              hint.isSafeForCurrentWireFormat,
              hint.isUsable(at: now),
              let observedAt = hint.observedAt,
              let expiresAt = hint.expiresAt,
              observedAt <= now.addingTimeInterval(5 * 60),
              observedAt >= now.addingTimeInterval(-60 * 60),
              expiresAt > now,
              expiresAt <= observedAt.addingTimeInterval(60 * 60) else {
            return false
        }
        return true
    }
}
