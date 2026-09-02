/// Versioned compound identity for one nested topology node.
///
/// Public encoding is structured JSON (not a delimiter-joined string) so opaque
/// provider raw IDs cannot collide with encoding separators.
///
/// ```json
/// {
///   "version": 1,
///   "provider_kind": "herdr",
///   "provider_instance_id": "…",
///   "node_kind": "pane",
///   "raw_id": "w2:p34"
/// }
/// ```
public struct NestedNodeID: Hashable, Codable, Sendable, Comparable {
    /// Current public encoding version for newly minted identifiers.
    public static let currentEncodingVersion: UInt8 = 1

    /// Encoding schema version.
    public let version: UInt8
    /// Provider that minted the raw ID.
    public let providerKind: NestedProviderKind
    /// Live provider instance / connection generation.
    public let providerInstanceID: NestedProviderInstanceID
    /// Node kind within the nested tree.
    public let kind: NestedNodeKind
    /// Opaque provider-native identifier. Never parsed by cmux.
    public let rawID: String

    enum CodingKeys: String, CodingKey {
        case version
        case providerKind = "provider_kind"
        case providerInstanceID = "provider_instance_id"
        case kind = "node_kind"
        case rawID = "raw_id"
    }

    /// Creates a compound nested node ID at the current encoding version.
    ///
    /// - Parameters:
    ///   - providerKind: Owning provider kind.
    ///   - providerInstanceID: Live provider instance identity.
    ///   - kind: Node kind.
    ///   - rawID: Opaque provider-native ID.
    public init(
        providerKind: NestedProviderKind,
        providerInstanceID: NestedProviderInstanceID,
        kind: NestedNodeKind,
        rawID: String
    ) {
        self.init(
            version: Self.currentEncodingVersion,
            providerKind: providerKind,
            providerInstanceID: providerInstanceID,
            kind: kind,
            rawID: rawID
        )
    }

    /// Creates a compound nested node ID with an explicit encoding version.
    ///
    /// - Parameters:
    ///   - version: Encoding schema version.
    ///   - providerKind: Owning provider kind.
    ///   - providerInstanceID: Live provider instance identity.
    ///   - kind: Node kind.
    ///   - rawID: Opaque provider-native ID.
    public init(
        version: UInt8,
        providerKind: NestedProviderKind,
        providerInstanceID: NestedProviderInstanceID,
        kind: NestedNodeKind,
        rawID: String
    ) {
        self.version = version
        self.providerKind = providerKind
        self.providerInstanceID = providerInstanceID
        self.kind = kind
        self.rawID = rawID
    }

    public static func < (lhs: NestedNodeID, rhs: NestedNodeID) -> Bool {
        if lhs.providerKind.rawValue != rhs.providerKind.rawValue {
            return lhs.providerKind.rawValue < rhs.providerKind.rawValue
        }
        if lhs.providerInstanceID != rhs.providerInstanceID {
            return lhs.providerInstanceID < rhs.providerInstanceID
        }
        if lhs.kind != rhs.kind {
            return lhs.kind < rhs.kind
        }
        if lhs.rawID != rhs.rawID {
            return lhs.rawID < rhs.rawID
        }
        return lhs.version < rhs.version
    }
}
