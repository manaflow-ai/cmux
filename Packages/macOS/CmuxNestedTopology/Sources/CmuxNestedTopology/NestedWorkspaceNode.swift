/// Immutable provider-owned workspace value.
public struct NestedWorkspaceNode: Codable, Equatable, Sendable {
    /// Compound workspace identity.
    public let id: NestedNodeID

    /// Provider order among sibling workspaces.
    public let order: Int

    /// Optional display title with explicit authority.
    public let title: NestedNodeTitle?

    /// Creates a provider-owned workspace value.
    ///
    /// - Parameters:
    ///   - id: Compound workspace identity.
    ///   - order: Provider order among sibling workspaces.
    ///   - title: Optional display title.
    public init(id: NestedNodeID, order: Int, title: NestedNodeTitle?) {
        self.id = id
        self.order = order
        self.title = title
    }

    func mergingUpdate(_ candidate: NestedWorkspaceNode) -> NestedWorkspaceNode {
        NestedWorkspaceNode(
            id: id,
            order: candidate.order,
            title: title?.replacingFromProvider(with: candidate.title) ?? candidate.title
        )
    }

    func replacingTitle(with title: NestedNodeTitle) -> NestedWorkspaceNode {
        NestedWorkspaceNode(
            id: id,
            order: order,
            title: self.title?.replacing(withLocalLock: title) ?? title
        )
    }

    func precedes(_ candidate: NestedWorkspaceNode) -> Bool {
        order == candidate.order
            ? ExactUTF8String(id.rawID) < ExactUTF8String(candidate.id.rawID)
            : order < candidate.order
    }
}

extension NestedWorkspaceNode: NestedTopologyTitledNode {}
