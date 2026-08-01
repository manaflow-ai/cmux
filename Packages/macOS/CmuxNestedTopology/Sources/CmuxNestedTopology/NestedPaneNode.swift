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
        NestedPaneNode(
            id: id,
            association: association.replacing(with: candidate.association),
            order: candidate.order,
            title: title?.replacing(with: candidate.title) ?? candidate.title
        )
    }
}
