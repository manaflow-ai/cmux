/// Pane parentage and order for structural diffs (no display title).
public struct NestedStructuralPane: Hashable, Sendable {
    /// Pane compound ID.
    public let id: NestedNodeID
    /// Parent tab compound ID.
    public let tabID: NestedNodeID
    /// Sibling order.
    public let orderIndex: Int

    /// Creates a structural pane row.
    public init(id: NestedNodeID, tabID: NestedNodeID, orderIndex: Int) {
        self.id = id
        self.tabID = tabID
        self.orderIndex = orderIndex
    }
}
