/// Versioned compound identity for a provider-owned virtual node.
///
/// Raw provider IDs never stand alone. Provider kind, instance generation, and
/// node kind are part of equality and hashing, preventing cross-attachment and
/// cross-level collisions.
public struct NestedNodeID: Codable, Hashable, Sendable {
    /// Identity encoding version produced and accepted by this package.
    public static let currentVersion: UInt8 = 1

    /// Structured identity encoding version.
    public let version: UInt8

    /// Provider implementation kind.
    public let providerKind: NestedProviderKind

    /// Provider instance and connection generation.
    public let providerInstanceID: NestedProviderInstanceID

    /// Topology level owned by this identity.
    public let kind: NestedNodeKind

    /// Provider-owned opaque node value preserved byte-for-byte on the wire.
    public let rawID: String

    /// Reconstituted provider identity represented by this node ID.
    public var providerIdentity: NestedProviderIdentity {
        NestedProviderIdentity(kind: providerKind, instanceID: providerInstanceID)
    }

    /// Creates a current-version compound node identity.
    ///
    /// - Parameters:
    ///   - provider: Provider instance and generation that own the node.
    ///   - kind: Fixed topology level.
    ///   - rawID: Provider-owned opaque node value.
    public init(provider: NestedProviderIdentity, kind: NestedNodeKind, rawID: String) {
        version = Self.currentVersion
        providerKind = provider.kind
        providerInstanceID = provider.instanceID
        self.kind = kind
        self.rawID = rawID
    }

    /// Compares every structured component while preserving exact opaque ID bytes.
    public static func == (lhs: NestedNodeID, rhs: NestedNodeID) -> Bool {
        lhs.version == rhs.version
            && lhs.providerKind == rhs.providerKind
            && lhs.providerInstanceID == rhs.providerInstanceID
            && lhs.kind == rhs.kind
            && ExactUTF8String(lhs.rawID) == ExactUTF8String(rhs.rawID)
    }

    /// Hashes every structured component while preserving exact opaque ID bytes.
    ///
    /// - Parameter hasher: Hasher receiving the identity components.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(version)
        hasher.combine(providerKind)
        hasher.combine(providerInstanceID)
        hasher.combine(kind)
        hasher.combine(ExactUTF8String(rawID))
    }

    /// Decodes a structured identity and rejects unsupported versions.
    ///
    /// - Parameter decoder: Decoder containing the structured identity.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(UInt8.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported nested node ID version \(version)"
            )
        }
        self.version = version
        providerKind = try container.decode(NestedProviderKind.self, forKey: .providerKind)
        providerInstanceID = try container.decode(
            NestedProviderInstanceID.self,
            forKey: .providerInstanceID
        )
        kind = try container.decode(NestedNodeKind.self, forKey: .kind)
        rawID = try container.decode(ExactUTF8String.self, forKey: .rawID).value
    }

    /// Encodes every component of the structured identity.
    ///
    /// - Parameter encoder: Encoder receiving the identity.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(providerKind, forKey: .providerKind)
        try container.encode(providerInstanceID, forKey: .providerInstanceID)
        try container.encode(kind, forKey: .kind)
        try container.encode(ExactUTF8String(rawID), forKey: .rawID)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case providerKind
        case providerInstanceID
        case kind
        case rawID
    }
}
