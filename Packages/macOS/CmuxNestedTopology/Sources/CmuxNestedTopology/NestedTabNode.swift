/// Provider-owned tab node nested under a workspace.
public struct NestedTabNode: Hashable, Codable, Sendable {
    /// Compound node identity.
    public let id: NestedNodeID
    /// Parent workspace compound ID.
    public let workspaceID: NestedNodeID
    /// Display title from the provider. Ignored by structural equality on the snapshot.
    public var displayTitle: String
    /// Stable sibling order within the parent workspace.
    public var orderIndex: Int

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspace_id"
        case displayTitle = "display_title"
        case orderIndex = "order_index"
    }

    /// Creates a tab node.
    public init(
        id: NestedNodeID,
        workspaceID: NestedNodeID,
        displayTitle: String,
        orderIndex: Int
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.displayTitle = displayTitle
        self.orderIndex = orderIndex
    }
}
