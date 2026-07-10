public import CMUXMobileCore
public import Foundation

/// One active endpoint binding returned by the authenticated trust broker.
public struct CmxIrohBrokerBinding: Decodable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case bindingID = "binding_id"
        case deviceID = "device_id"
        case appInstanceID = "app_instance_id"
        case tag
        case platform
        case displayName = "display_name"
        case endpointID = "endpoint_id"
        case identityGeneration = "identity_generation"
        case pairingEnabled = "pairing_enabled"
        case capabilities
        case pathHints = "path_hints"
        case lastSeenAt = "last_seen_at"
    }

    public let bindingID: String
    public let deviceID: String
    public let appInstanceID: String
    public let tag: String
    public let platform: CmxIrohPlatform
    public let displayName: String?
    public let endpointID: CmxIrohPeerIdentity
    public let identityGeneration: Int
    public let pairingEnabled: Bool
    public let capabilities: [String]
    public let pathHints: [CmxIrohPathHint]
    public let lastSeenAt: String

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bindingID = try container.decode(String.self, forKey: .bindingID)
        let deviceID = try container.decode(String.self, forKey: .deviceID)
        let appInstanceID = try container.decode(String.self, forKey: .appInstanceID)
        let tag = try container.decode(String.self, forKey: .tag)
        let endpointID = try container.decode(String.self, forKey: .endpointID)
        let identityGeneration = try container.decode(Int.self, forKey: .identityGeneration)
        let capabilities = try container.decode([String].self, forKey: .capabilities)
        guard Self.isCanonicalUUID(bindingID),
              Self.isCanonicalUUID(deviceID),
              Self.isCanonicalUUID(appInstanceID),
              Self.isSafeToken(tag),
              (1 ... Int(Int32.max)).contains(identityGeneration),
              capabilities.count <= 32,
              Set(capabilities).count == capabilities.count,
              capabilities.allSatisfy(Self.isSafeToken) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid Iroh binding")
            )
        }
        self.bindingID = bindingID
        self.deviceID = deviceID
        self.appInstanceID = appInstanceID
        self.tag = tag
        platform = try container.decode(CmxIrohPlatform.self, forKey: .platform)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        self.endpointID = try CmxIrohPeerIdentity(endpointID: endpointID)
        self.identityGeneration = identityGeneration
        pairingEnabled = try container.decode(Bool.self, forKey: .pairingEnabled)
        self.capabilities = capabilities
        pathHints = try container.decode([CmxIrohPathHint].self, forKey: .pathHints)
        lastSeenAt = try container.decode(String.self, forKey: .lastSeenAt)
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func isSafeToken(_ value: String) -> Bool {
        guard (1 ... 64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || [45, 46, 58, 95].contains(byte)
        }
    }
}

/// Broker-published Ed25519 key used to verify grants and attestations locally.
public struct CmxIrohGrantVerificationKey: Decodable, Equatable, Sendable {
    public let kid: String
    public let alg: String
    public let spkiDerBase64: String

    private enum CodingKeys: String, CodingKey {
        case kid
        case alg
        case spkiDerBase64 = "spki_der_base64"
    }
}

/// Current and previous broker keys accepted during a staged signing-key rotation.
public struct CmxIrohGrantVerificationKeySet: Decodable, Equatable, Sendable {
    public let version: Int
    public let currentKeyID: String
    public let keys: [CmxIrohGrantVerificationKey]

    private enum CodingKeys: String, CodingKey {
        case version
        case currentKeyID = "current_kid"
        case keys
    }
}

/// Same-account LAN rendezvous material. It is never advertised directly in mDNS.
public struct CmxIrohLANRendezvous: Decodable, Equatable, Sendable {
    public let generation: Int
    public let key: String
}

/// Authenticated registry snapshot used for endpoint discovery and grant verification.
public struct CmxIrohDiscoveryResponse: Decodable, Equatable, Sendable {
    public let routeContractVersion: Int
    public let bindings: [CmxIrohBrokerBinding]
    public let relayFleet: [String]
    public let lanRendezvous: CmxIrohLANRendezvous
    public let grantVerificationKeys: CmxIrohGrantVerificationKeySet

    private enum CodingKeys: String, CodingKey {
        case routeContractVersion = "route_contract_version"
        case bindings
        case relayFleet = "relay_fleet"
        case lanRendezvous = "lan_rendezvous"
        case grantVerificationKeys = "grant_verification_keys"
    }
}

/// Endpoint-scoped relay credential minted for the complete managed fleet.
public struct CmxIrohRelayTokenResponse: Decodable, Equatable, Sendable {
    public let token: String
    public let expiresAt: String
    public let refreshAfter: String
    public let relayFleet: [String]

    private enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
        case refreshAfter = "refresh_after"
        case relayFleet = "relay_fleet"
    }

    /// Validates the broker timestamps and creates one credential per relay.
    public func relayConfigurations(now: Date) throws -> [CmxIrohRelayConfiguration] {
        guard let expiresAt = Self.date(expiresAt),
              let refreshAfter = Self.date(refreshAfter) else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
        return try relayFleet.map { url in
            try CmxIrohRelayConfiguration(
                url: url,
                token: token,
                expiresAt: expiresAt,
                refreshAfter: refreshAfter,
                now: now
            )
        }
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// Registration response. Relay bootstrap failure never rolls back the binding.
public struct CmxIrohRegistrationResponse: Decodable, Equatable, Sendable {
    public let binding: CmxIrohBrokerBinding
    public let relay: CmxIrohRegistrationRelay
}

/// Result of the registration route's best-effort initial relay mint.
public enum CmxIrohRegistrationRelay: Decodable, Equatable, Sendable {
    case issued(CmxIrohRelayTokenResponse)
    case unavailable

    private enum CodingKeys: String, CodingKey { case status }

    public init(from decoder: any Decoder) throws {
        let status = try decoder.container(keyedBy: CodingKeys.self)
            .decode(String.self, forKey: .status)
        switch status {
        case "issued":
            self = try .issued(CmxIrohRelayTokenResponse(from: decoder))
        case "unavailable":
            self = .unavailable
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown relay status")
            )
        }
    }
}

/// Backend-signed seven-day permission for one iOS initiator and Mac acceptor.
public struct CmxIrohPairGrantResponse: Decodable, Equatable, Sendable {
    public let grant: String
    public let expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case grant
        case expiresAt = "expires_at"
    }
}

/// Backend-signed endpoint/account proof cached for offline same-account pairing.
public struct CmxIrohEndpointAttestationResponse: Decodable, Equatable, Sendable {
    public let attestationVersion: Int
    public let attestation: String
    public let expiresAt: String
    public let grantVerificationKeys: CmxIrohGrantVerificationKeySet

    private enum CodingKeys: String, CodingKey {
        case attestationVersion = "attestation_version"
        case attestation
        case expiresAt = "expires_at"
        case grantVerificationKeys = "grant_verification_keys"
    }
}
