public import CMUXMobileCore
public import Foundation

/// One active endpoint binding returned by the authenticated trust broker.
public struct CmxIrohBrokerBinding: Codable, Equatable, Sendable {
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
        case directPorts = "direct_ports"
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
    public let directPorts: CmxIrohDirectPorts?
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
        let displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        let pathHints = try container.decode([CmxIrohPathHint].self, forKey: .pathHints)
        let directPorts = try container.decodeIfPresent(
            CmxIrohDirectPorts.self,
            forKey: .directPorts
        )
        let lastSeenAt = try container.decode(String.self, forKey: .lastSeenAt)
        guard Self.isCanonicalUUID(bindingID),
              Self.isCanonicalUUID(deviceID),
              Self.isCanonicalUUID(appInstanceID),
              Self.isSafeToken(tag),
              (1 ... Int(Int32.max)).contains(identityGeneration),
              capabilities.count <= 32,
              Set(capabilities).count == capabilities.count,
              capabilities.allSatisfy(Self.isSafeToken),
              displayName.map(Self.isSafeDisplayName) ?? true,
              pathHints.count <= CmxAttachEndpoint.maximumIrohPathHintCount,
              pathHints.filter({ $0.kind == .relayURL }).count <= 2,
              pathHints.allSatisfy(Self.isBrokerHint),
              !pathHints.enumerated().contains(where: { index, hint in
                  pathHints[..<index].contains(hint)
              }),
              CmxIrohISO8601Date.parse(lastSeenAt) != nil else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid Iroh binding")
            )
        }
        self.bindingID = bindingID
        self.deviceID = deviceID
        self.appInstanceID = appInstanceID
        self.tag = tag
        platform = try container.decode(CmxIrohPlatform.self, forKey: .platform)
        self.displayName = displayName
        self.endpointID = try CmxIrohPeerIdentity(endpointID: endpointID)
        self.identityGeneration = identityGeneration
        pairingEnabled = try container.decode(Bool.self, forKey: .pairingEnabled)
        self.capabilities = capabilities
        self.pathHints = pathHints
        self.directPorts = directPorts
        self.lastSeenAt = lastSeenAt
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bindingID, forKey: .bindingID)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(appInstanceID, forKey: .appInstanceID)
        try container.encode(tag, forKey: .tag)
        try container.encode(platform, forKey: .platform)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encode(endpointID.endpointID, forKey: .endpointID)
        try container.encode(identityGeneration, forKey: .identityGeneration)
        try container.encode(pairingEnabled, forKey: .pairingEnabled)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(pathHints, forKey: .pathHints)
        try container.encodeIfPresent(directPorts, forKey: .directPorts)
        try container.encode(lastSeenAt, forKey: .lastSeenAt)
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

    private static func isSafeDisplayName(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf16.count <= 128
            && !value.unicodeScalars.contains(where: {
                $0.value <= 0x1f || $0.value == 0x7f
            })
    }

    private static func isBrokerHint(_ hint: CmxIrohPathHint) -> Bool {
        guard hint.isSafeForCurrentWireFormat,
              hint.kind != .relayIdentifier,
              let observedAt = hint.observedAt,
              let expiresAt = hint.expiresAt,
              expiresAt > observedAt,
              expiresAt <= observedAt.addingTimeInterval(CmxIrohPathHint.maximumPrivateHintTTL)
        else {
            return false
        }
        return true
    }

}

/// Broker-published Ed25519 key used to verify grants and attestations locally.
public struct CmxIrohGrantVerificationKey: Codable, Equatable, Sendable {
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
public struct CmxIrohGrantVerificationKeySet: Codable, Equatable, Sendable {
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
public struct CmxIrohLANRendezvous: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case generation
        case key
    }

    public let generation: Int
    public let key: String

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let generation = try container.decode(Int.self, forKey: .generation)
        let key = try container.decode(String.self, forKey: .key)
        guard (1 ... Int(Int32.max)).contains(generation),
              Self.decodeBase64URL(key)?.count == 32 else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid LAN rendezvous")
            )
        }
        self.generation = generation
        self.key = key
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte)
                      || (65 ... 90).contains(byte)
                      || (97 ... 122).contains(byte)
                      || byte == 45 || byte == 95
              }) else {
            return nil
        }
        let padding = String(repeating: "=", count: (4 - value.count % 4) % 4)
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        guard let data = Data(base64Encoded: standard),
              data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "") == value else {
            return nil
        }
        return data
    }
}

/// Authenticated registry snapshot used for endpoint discovery and grant verification.
public struct CmxIrohDiscoveryResponse: Decodable, Equatable, Sendable {
    /// Upper bound for one authenticated account snapshot. Production accounts
    /// remain server-limited to 32; development accounts may use this larger,
    /// still-bounded snapshot for concurrent tagged builds.
    public static let maximumBindingCount = 256

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

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let routeContractVersion = try container.decode(Int.self, forKey: .routeContractVersion)
        let bindings = try container.decode([CmxIrohBrokerBinding].self, forKey: .bindings)
        let relayFleet = try container.decode([String].self, forKey: .relayFleet)
        guard bindings.count <= Self.maximumBindingCount,
              Set(bindings.map(\.bindingID)).count == bindings.count,
              (1 ... CmxIrohRelayPolicyVerifier.maximumRelayCount).contains(
                  relayFleet.count
              ),
              Set(relayFleet).count == relayFleet.count,
              relayFleet.allSatisfy(Self.isCanonicalRelayURL) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid Iroh registry")
            )
        }
        self.routeContractVersion = routeContractVersion
        self.bindings = bindings
        self.relayFleet = relayFleet
        lanRendezvous = try container.decode(CmxIrohLANRendezvous.self, forKey: .lanRendezvous)
        grantVerificationKeys = try container.decode(
            CmxIrohGrantVerificationKeySet.self,
            forKey: .grantVerificationKeys
        )
    }

    private static func isCanonicalRelayURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme == "https",
              let host = components.host,
              host == host.lowercased(),
              !host.isEmpty,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path == "/" else {
            return false
        }
        return components.string == value
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
    case notRequested

    private enum CodingKeys: String, CodingKey { case status }

    public init(from decoder: any Decoder) throws {
        let status = try decoder.container(keyedBy: CodingKeys.self)
            .decode(String.self, forKey: .status)
        switch status {
        case "issued":
            self = try .issued(CmxIrohRelayTokenResponse(from: decoder))
        case "unavailable":
            self = .unavailable
        case "not_requested":
            self = .notRequested
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown relay status")
            )
        }
    }
}

/// Backend-signed seven-day permission for one iOS initiator and Mac acceptor.
public struct CmxIrohPairGrantResponse: Codable, Equatable, Sendable {
    public let grant: String
    public let expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case grant
        case expiresAt = "expires_at"
    }
}

/// Backend-signed endpoint/account proof cached for offline same-account pairing.
public struct CmxIrohEndpointAttestationResponse: Codable, Equatable, Sendable {
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
