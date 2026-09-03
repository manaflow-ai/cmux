/// In-memory association key for native nested topology.
///
/// Mirrors the plugin `pane_id:session_id` contract using compound nested IDs
/// plus provider instance generation. This is intentionally not a public
/// `system.tree` node ID.
public struct NestedAssociationKey: Hashable, Codable, Sendable {
    /// Compound nested node identity (typically a pane).
    public let nodeID: NestedNodeID
    /// Opaque session / agent conversation token when known.
    public let sessionRawID: String
    /// Provider instance generation that minted the association.
    public let providerInstanceGeneration: NestedProviderInstanceID

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case sessionRawID = "session_raw_id"
        case providerInstanceGeneration = "provider_instance_generation"
    }

    /// Creates an association key.
    public init(
        nodeID: NestedNodeID,
        sessionRawID: String,
        providerInstanceGeneration: NestedProviderInstanceID
    ) {
        self.nodeID = nodeID
        self.sessionRawID = sessionRawID
        self.providerInstanceGeneration = providerInstanceGeneration
    }
}
