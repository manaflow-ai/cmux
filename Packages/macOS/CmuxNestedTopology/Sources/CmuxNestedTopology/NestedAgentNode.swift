/// Immutable agent value owned by a provider pane.
public struct NestedAgentNode: Codable, Equatable, Sendable {
    /// Compound agent identity.
    public let id: NestedNodeID

    /// Provider-owned parent pane.
    public let paneID: NestedNodeID

    /// Optional provider conversation or agent session value.
    public let sessionID: String?

    /// Provider order among sibling agents.
    public let order: Int

    /// Optional display title with explicit authority.
    public let title: NestedNodeTitle?

    /// Normalized status with original provider value retained.
    public let status: NestedAgentStatus

    /// Creates a provider-owned agent value.
    ///
    /// - Parameters:
    ///   - id: Compound agent identity.
    ///   - paneID: Provider-owned parent pane.
    ///   - sessionID: Optional provider session value.
    ///   - order: Provider order among sibling agents.
    ///   - title: Optional display title.
    ///   - status: Normalized and raw provider status.
    public init(
        id: NestedNodeID,
        paneID: NestedNodeID,
        sessionID: String?,
        order: Int,
        title: NestedNodeTitle?,
        status: NestedAgentStatus
    ) {
        self.id = id
        self.paneID = paneID
        self.sessionID = sessionID
        self.order = order
        self.title = title
        self.status = status
    }

    func mergingUpdate(_ candidate: NestedAgentNode) -> NestedAgentNode {
        NestedAgentNode(
            id: id,
            paneID: candidate.paneID,
            sessionID: candidate.sessionID,
            order: candidate.order,
            title: title?.replacing(with: candidate.title) ?? candidate.title,
            status: candidate.status
        )
    }
}
