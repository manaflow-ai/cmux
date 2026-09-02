/// Tab parentage and order for structural diffs (no display title).
public struct NestedStructuralTab: Hashable, Sendable {
    /// Tab compound ID.
    public let id: NestedNodeID
    /// Parent workspace compound ID.
    public let workspaceID: NestedNodeID
    /// Sibling order.
    public let orderIndex: Int

    /// Creates a structural tab row.
    public init(id: NestedNodeID, workspaceID: NestedNodeID, orderIndex: Int) {
        self.id = id
        self.workspaceID = workspaceID
        self.orderIndex = orderIndex
    }
}
