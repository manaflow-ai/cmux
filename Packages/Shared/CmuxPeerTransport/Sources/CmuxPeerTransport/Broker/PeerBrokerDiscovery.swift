import Foundation

/// Broker-published Ed25519 key used to verify grants and attestations locally.
public struct PeerGrantVerificationKey: Codable, Equatable, Sendable {
    public let kid: String
    public let alg: String
    public let spkiDerBase64: String

    private enum CodingKeys: String, CodingKey {
        case kid
        case alg
        case spkiDerBase64 = "spki_der_base64"
    }

    public init(kid: String, alg: String, spkiDerBase64: String) {
        self.kid = kid
        self.alg = alg
        self.spkiDerBase64 = spkiDerBase64
    }
}

/// Current and previous broker keys accepted during a staged key rotation.
public struct PeerGrantVerificationKeySet: Codable, Equatable, Sendable {
    public let version: Int
    public let currentKeyID: String
    public let keys: [PeerGrantVerificationKey]

    private enum CodingKeys: String, CodingKey {
        case version
        case currentKeyID = "current_kid"
        case keys
    }

    public init(version: Int, currentKeyID: String, keys: [PeerGrantVerificationKey]) {
        self.version = version
        self.currentKeyID = currentKeyID
        self.keys = keys
    }
}

/// Same-account LAN rendezvous material. Never advertised directly in mDNS.
public struct PeerBrokerLANRendezvous: Codable, Equatable, Sendable {
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
              PeerBrokerWire.decodeBase64URL(key)?.count == 32 else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid LAN rendezvous")
            )
        }
        self.generation = generation
        self.key = key
    }
}

/// Authenticated registry snapshot used for discovery and grant verification.
public struct PeerBrokerDiscoverySnapshot: Codable, Equatable, Sendable {
    public let routeContractVersion: Int
    /// Monotonic account route revision returned by revision-aware brokers.
    public let revision: UInt64?
    public let bindings: [PeerBrokerBinding]
    public let relayFleet: [String]
    public let lanRendezvous: PeerBrokerLANRendezvous
    public let grantVerificationKeys: PeerGrantVerificationKeySet

    private enum CodingKeys: String, CodingKey {
        case routeContractVersion = "route_contract_version"
        case revision
        case bindings
        case relayFleet = "relay_fleet"
        case lanRendezvous = "lan_rendezvous"
        case grantVerificationKeys = "grant_verification_keys"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let routeContractVersion = try container.decode(Int.self, forKey: .routeContractVersion)
        let revision = try container.decodeIfPresent(UInt64.self, forKey: .revision)
        let bindings = try container.decode([PeerBrokerBinding].self, forKey: .bindings)
        let relayFleet = try container.decode([String].self, forKey: .relayFleet)
        guard Set(bindings.map(\.bindingID)).count == bindings.count,
              (1 ... PeerBrokerWire.maximumRelayCount).contains(relayFleet.count),
              Set(relayFleet).count == relayFleet.count,
              relayFleet.allSatisfy(PeerBrokerWire.isCanonicalRelayURL) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid registry")
            )
        }
        self.routeContractVersion = routeContractVersion
        self.revision = revision
        self.bindings = bindings
        self.relayFleet = relayFleet
        lanRendezvous = try container.decode(PeerBrokerLANRendezvous.self, forKey: .lanRendezvous)
        grantVerificationKeys = try container.decode(
            PeerGrantVerificationKeySet.self,
            forKey: .grantVerificationKeys
        )
    }

    init(
        routeContractVersion: Int,
        revision: UInt64?,
        bindings: [PeerBrokerBinding],
        relayFleet: [String],
        lanRendezvous: PeerBrokerLANRendezvous,
        grantVerificationKeys: PeerGrantVerificationKeySet
    ) {
        self.routeContractVersion = routeContractVersion
        self.revision = revision
        self.bindings = bindings
        self.relayFleet = relayFleet
        self.lanRendezvous = lanRendezvous
        self.grantVerificationKeys = grantVerificationKeys
    }
}

/// One bounded broker response page used to assemble an account discovery.
struct PeerBrokerDiscoveryPage: Decodable, Sendable {
    static let bindingLimit = 128
    static let legacyBindingLimit = 256
    private static let cursorByteLimit = 256

    let discovery: PeerBrokerDiscoverySnapshot
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case nextCursor = "next_cursor"
    }

    init(from decoder: any Decoder) throws {
        let discovery = try PeerBrokerDiscoverySnapshot(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        let validCursor = nextCursor.map(Self.isSafeCursor) ?? true
        let validCount = if nextCursor == nil {
            discovery.bindings.count <= Self.legacyBindingLimit
        } else {
            discovery.bindings.count == Self.bindingLimit
        }
        guard validCursor, validCount else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid discovery page"
                )
            )
        }
        self.discovery = discovery
        self.nextCursor = nextCursor
    }

    private static func isSafeCursor(_ value: String) -> Bool {
        (1 ... cursorByteLimit).contains(value.utf8.count)
            && value.utf8.allSatisfy { byte in
                (48 ... 57).contains(byte)
                    || (65 ... 90).contains(byte)
                    || (97 ... 122).contains(byte)
                    || byte == 45
                    || byte == 95
            }
    }
}
