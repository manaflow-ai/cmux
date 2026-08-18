public import CMUXMobileCore
import Foundation

/// Platform role bound into registration, pairing, and grant credentials.
public enum PeerPlatform: String, Codable, Equatable, Sendable {
    case mac
    case ios
}

/// The endpoint-observed UDP ports for private IPv4 and IPv6 paths.
///
/// A port contains no private address and never contributes peer identity or
/// authorization. Same wire shape as the previous transport.
public struct PeerBrokerDirectPorts: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case ipv4
        case ipv6
    }

    public let ipv4: UInt16?
    public let ipv6: UInt16?

    public init(ipv4: UInt16? = nil, ipv6: UInt16? = nil) throws {
        guard ipv4 != nil || ipv6 != nil,
              ipv4.map({ $0 != 0 }) ?? true,
              ipv6.map({ $0 != 0 }) ?? true else {
            throw PeerBrokerDirectPortsError.empty
        }
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            ipv4: container.decodeIfPresent(UInt16.self, forKey: .ipv4),
            ipv6: container.decodeIfPresent(UInt16.self, forKey: .ipv6)
        )
    }
}

public enum PeerBrokerDirectPortsError: Error, Equatable, Sendable {
    case empty
}

/// One active endpoint binding returned by the authenticated trust broker.
///
/// Wire format is unchanged from the previous transport (snake_case keys,
/// identical validation), so broker responses and previously persisted
/// records decode identically.
public struct PeerBrokerBinding: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case bindingID = "binding_id"
        case deviceID = "device_id"
        case appInstanceID = "app_instance_id"
        case clientNamespace = "client_namespace"
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
    /// The exact bundle-derived app namespace that owns this binding.
    public let clientNamespace: String
    public let tag: String
    public let platform: PeerPlatform
    public let displayName: String?
    public let endpointID: CmxIrohPeerIdentity
    public let identityGeneration: Int
    public let pairingEnabled: Bool
    public let capabilities: [String]
    public let pathHints: [CmxIrohPathHint]
    public let directPorts: PeerBrokerDirectPorts?
    public let lastSeenAt: String

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bindingID = try container.decode(String.self, forKey: .bindingID)
        let deviceID = try container.decode(String.self, forKey: .deviceID)
        let appInstanceID = try container.decode(String.self, forKey: .appInstanceID)
        let clientNamespace = try container.decodeIfPresent(
            String.self,
            forKey: .clientNamespace
        ) ?? "legacy"
        let tag = try container.decode(String.self, forKey: .tag)
        let endpointID = try container.decode(String.self, forKey: .endpointID)
        let identityGeneration = try container.decode(Int.self, forKey: .identityGeneration)
        let capabilities = try container.decode([String].self, forKey: .capabilities)
        let displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        let pathHints = try container.decode([CmxIrohPathHint].self, forKey: .pathHints)
        let directPorts = try container.decodeIfPresent(
            PeerBrokerDirectPorts.self,
            forKey: .directPorts
        )
        let lastSeenAt = try container.decode(String.self, forKey: .lastSeenAt)
        guard PeerBrokerWire.isCanonicalUUID(bindingID),
              PeerBrokerWire.isCanonicalUUID(deviceID),
              PeerBrokerWire.isCanonicalUUID(appInstanceID),
              PeerBrokerWire.isSafeClientNamespace(clientNamespace),
              PeerBrokerWire.isSafeToken(tag),
              (1 ... Int(Int32.max)).contains(identityGeneration),
              capabilities.count <= 32,
              Set(capabilities).count == capabilities.count,
              capabilities.allSatisfy({ PeerBrokerWire.isSafeToken($0) }),
              displayName.map(PeerBrokerWire.isSafeDisplayName) ?? true,
              pathHints.count <= CmxAttachEndpoint.maximumIrohPathHintCount,
              pathHints.filter({ $0.kind == .relayURL }).count <= 2,
              pathHints.allSatisfy(Self.isBrokerHint),
              !pathHints.enumerated().contains(where: { index, hint in
                  pathHints[..<index].contains(hint)
              }),
              PeerBrokerWire.parseISO8601(lastSeenAt) != nil else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid binding")
            )
        }
        self.bindingID = bindingID
        self.deviceID = deviceID
        self.appInstanceID = appInstanceID
        self.clientNamespace = clientNamespace
        self.tag = tag
        platform = try container.decode(PeerPlatform.self, forKey: .platform)
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
        try container.encode(clientNamespace, forKey: .clientNamespace)
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

    /// Whether two rows carry the same authority-relevant tuple, ignoring
    /// volatile reachability fields (hints, ports, last-seen, display name).
    public func sameAuthority(as other: Self) -> Bool {
        bindingID == other.bindingID
            && deviceID == other.deviceID
            && appInstanceID == other.appInstanceID
            && clientNamespace == other.clientNamespace
            && tag == other.tag
            && platform == other.platform
            && endpointID == other.endpointID
            && identityGeneration == other.identityGeneration
            && pairingEnabled == other.pairingEnabled
            && capabilities.count == other.capabilities.count
            && Set(capabilities) == Set(other.capabilities)
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
