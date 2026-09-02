/// Provider-owned pane node nested under a tab.
public struct NestedPaneNode: Hashable, Codable, Sendable {
    /// Compound node identity.
    public let id: NestedNodeID
    /// Parent tab compound ID.
    public let tabID: NestedNodeID
    /// Display title from the provider. Ignored by structural equality on the snapshot.
    public var displayTitle: String
    /// Stable sibling order within the parent tab.
    public var orderIndex: Int

    enum CodingKeys: String, CodingKey {
        case id
        case tabID = "tab_id"
        case displayTitle = "display_title"
        case orderIndex = "order_index"
    }

    /// Creates a pane node.
    public init(
        id: NestedNodeID,
        tabID: NestedNodeID,
        displayTitle: String,
        orderIndex: Int
    ) {
        self.id = id
        self.tabID = tabID
        self.displayTitle = displayTitle
        self.orderIndex = orderIndex
    }
}
