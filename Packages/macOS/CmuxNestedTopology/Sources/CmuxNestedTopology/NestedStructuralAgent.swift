/// Agent parentage, status, and order for structural diffs (no display title).
public struct NestedStructuralAgent: Hashable, Sendable {
    /// Agent compound ID.
    public let id: NestedNodeID
    /// Parent pane compound ID.
    public let paneID: NestedNodeID
    /// Normalized status.
    public let status: NestedAgentStatus
    /// Sibling order.
    public let orderIndex: Int

    /// Creates a structural agent row.
    public init(
        id: NestedNodeID,
        paneID: NestedNodeID,
        status: NestedAgentStatus,
        orderIndex: Int
    ) {
        self.id = id
        self.paneID = paneID
        self.status = status
        self.orderIndex = orderIndex
    }
}
