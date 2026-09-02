/// Provider-owned workspace node in a nested topology snapshot.
public struct NestedWorkspaceNode: Hashable, Codable, Sendable {
    /// Compound node identity.
    public let id: NestedNodeID
    /// Display title from the provider. Ignored by structural equality on the snapshot.
    public var displayTitle: String
    /// Stable sibling order within the provider snapshot.
    public var orderIndex: Int

    enum CodingKeys: String, CodingKey {
        case id
        case displayTitle = "display_title"
        case orderIndex = "order_index"
    }

    /// Creates a workspace node.
    ///
    /// - Parameters:
    ///   - id: Compound ID whose kind must be ``NestedNodeKind/workspace``.
    ///   - displayTitle: Provider display title.
    ///   - orderIndex: Deterministic sibling order.
    public init(id: NestedNodeID, displayTitle: String, orderIndex: Int) {
        self.id = id
        self.displayTitle = displayTitle
        self.orderIndex = orderIndex
    }
}
