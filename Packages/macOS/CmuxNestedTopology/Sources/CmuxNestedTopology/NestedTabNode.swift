/// Immutable provider-owned tab value.
public struct NestedTabNode: Codable, Equatable, Sendable {
    /// Compound tab identity.
    public let id: NestedNodeID

    /// Provider-owned parent workspace.
    public let workspaceID: NestedNodeID

    /// Provider order among sibling tabs.
    public let order: Int

    /// Optional display title with explicit authority.
    public let title: NestedNodeTitle?

    /// Creates a provider-owned tab value.
    ///
    /// - Parameters:
    ///   - id: Compound tab identity.
    ///   - workspaceID: Provider-owned parent workspace.
    ///   - order: Provider order among sibling tabs.
    ///   - title: Optional display title.
    public init(
        id: NestedNodeID,
        workspaceID: NestedNodeID,
        order: Int,
        title: NestedNodeTitle?
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.order = order
        self.title = title
    }

    func mergingUpdate(_ candidate: NestedTabNode) -> NestedTabNode {
        NestedTabNode(
            id: id,
            workspaceID: candidate.workspaceID,
            order: candidate.order,
            title: title?.replacingFromProvider(with: candidate.title) ?? candidate.title
        )
    }

    func replacingTitle(with title: NestedNodeTitle) -> NestedTabNode {
        NestedTabNode(
            id: id,
            workspaceID: workspaceID,
            order: order,
            title: self.title?.replacing(withLocalLock: title) ?? title
        )
    }

    func precedes(_ candidate: NestedTabNode) -> Bool {
        let parent = ExactUTF8String(workspaceID.rawID)
        let candidateParent = ExactUTF8String(candidate.workspaceID.rawID)
        if parent != candidateParent {
            return parent < candidateParent
        }
        return order == candidate.order
            ? ExactUTF8String(id.rawID) < ExactUTF8String(candidate.id.rawID)
            : order < candidate.order
    }
}

extension NestedTabNode: NestedTopologyTitledNode {}
