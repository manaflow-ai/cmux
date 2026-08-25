/// Immutable provider-owned pane value.
///
/// A nested pane is virtual cmux topology. It is not a Bonsplit pane, Ghostty
/// surface, or local PTY owner.
public struct NestedPaneNode: Codable, Equatable, Sendable {
    /// Compound pane identity.
    public let id: NestedNodeID

    /// Resolved tab parent and heuristic-once state.
    public let association: NestedParentAssociation

    /// Provider order among sibling panes.
    public let order: Int

    /// Optional display title with explicit authority.
    public let title: NestedNodeTitle?

    /// Creates a provider-owned pane value.
    ///
    /// - Parameters:
    ///   - id: Compound pane identity.
    ///   - association: Resolved parent and heuristic state.
    ///   - order: Provider order among sibling panes.
    ///   - title: Optional display title.
    public init(
        id: NestedNodeID,
        association: NestedParentAssociation,
        order: Int,
        title: NestedNodeTitle?
    ) {
        self.id = id
        self.association = association
        self.order = order
        self.title = title
    }

    func mergingUpdate(_ candidate: NestedPaneNode) -> NestedPaneNode {
        let rejectsSupersededSession = association.rejectsSupersededSession(candidate.association)
        let preservesTitleAfterRejectedHeuristic = association.rejectsRepeatedHeuristic(
            candidate.association
        ) && candidate.title?.authority != .provider
        return NestedPaneNode(
            id: id,
            association: association.replacing(with: candidate.association),
            order: rejectsSupersededSession ? order : candidate.order,
            title: rejectsSupersededSession || preservesTitleAfterRejectedHeuristic
                ? title
                : title?.replacingFromProvider(with: candidate.title) ?? candidate.title
        )
    }

    func replacingTitle(with title: NestedNodeTitle) -> NestedPaneNode {
        NestedPaneNode(
            id: id,
            association: association,
            order: order,
            title: self.title?.replacing(withLocalLock: title) ?? title
        )
    }

    func precedes(_ candidate: NestedPaneNode) -> Bool {
        let parent = ExactUTF8String(association.tabID.rawID)
        let candidateParent = ExactUTF8String(candidate.association.tabID.rawID)
        if parent != candidateParent {
            return parent < candidateParent
        }
        return order == candidate.order
            ? ExactUTF8String(id.rawID) < ExactUTF8String(candidate.id.rawID)
            : order < candidate.order
    }
}

extension NestedPaneNode: NestedTopologyTitledNode {}
