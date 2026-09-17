/// Provider-owned agent node nested under a pane.
public struct NestedAgentNode: Hashable, Codable, Sendable {
    /// Compound node identity.
    public let id: NestedNodeID
    /// Parent pane compound ID.
    public let paneID: NestedNodeID
    /// Display title from the provider. Ignored by structural equality on the snapshot.
    public var displayTitle: String
    /// Normalized presentation status.
    public var status: NestedAgentStatus
    /// Original provider status token retained for forward compatibility.
    public var providerRawStatus: String
    /// Stable sibling order within the parent pane.
    public var orderIndex: Int

    enum CodingKeys: String, CodingKey {
        case id
        case paneID = "pane_id"
        case displayTitle = "display_title"
        case status
        case providerRawStatus = "provider_raw_status"
        case orderIndex = "order_index"
    }

    /// Creates an agent node.
    public init(
        id: NestedNodeID,
        paneID: NestedNodeID,
        displayTitle: String,
        status: NestedAgentStatus,
        providerRawStatus: String,
        orderIndex: Int
    ) {
        self.id = id
        self.paneID = paneID
        self.displayTitle = displayTitle
        self.status = status
        self.providerRawStatus = providerRawStatus
        self.orderIndex = orderIndex
    }
}
