/// Deterministic validation or reduction failure for nested topology.
public enum NestedTopologyError: Error, Equatable, Sendable {
    /// A configured resource limit is not positive.
    case invalidLimit(name: String, value: Int)

    /// A required provider value is empty.
    case emptyField(name: String)

    /// A bounded string exceeds its UTF-8 byte budget.
    case fieldTooLarge(name: String, actualBytes: Int, maximumBytes: Int)

    /// Untrusted display or protocol text contains a control character.
    case controlCharacter(name: String)

    /// A node collection exceeds its per-kind budget.
    case nodeLimitExceeded(kind: NestedNodeKind, actual: Int, maximum: Int)

    /// Total node count exceeds the snapshot budget.
    case totalNodeLimitExceeded(actual: Int, maximum: Int)

    /// An atomic provider event batch exceeds its configured budget.
    case eventBatchLimitExceeded(actual: Int, maximum: Int)

    /// Capability count exceeds the snapshot budget.
    case capabilityLimitExceeded(actual: Int, maximum: Int)

    /// A node is deeper than the configured hierarchy limit.
    case depthLimitExceeded(kind: NestedNodeKind, maximumDepth: Int)

    /// An identity appears in a collection for another node kind.
    case invalidNodeKind(id: NestedNodeID, expected: NestedNodeKind)

    /// Event, node, or parent belongs to another provider generation.
    case providerMismatch(expected: NestedProviderIdentity, actual: NestedProviderIdentity)

    /// Snapshot or create event repeats an existing compound identity.
    case duplicateNode(id: NestedNodeID)

    /// Update or focus references a node absent from the current snapshot.
    case missingNode(id: NestedNodeID)

    /// A typed parent identity has the wrong topology level.
    case invalidParentKind(node: NestedNodeID, parent: NestedNodeID, expected: NestedNodeKind)

    /// A correctly typed parent does not exist in the current snapshot.
    case missingParent(node: NestedNodeID, parent: NestedNodeID)

    /// A pane association key does not identify that pane.
    case invalidAssociationKey(pane: NestedNodeID, keyPane: NestedNodeID)

    /// A heuristic parent was recorded without consuming its one-shot lock.
    case invalidHeuristicState(pane: NestedNodeID)

    /// Provider order must be nonnegative.
    case invalidOrder(node: NestedNodeID, order: Int)

    /// Provider input attempted to claim cmux-owned title authority.
    case invalidProviderTitleAuthority(node: NestedNodeID, authority: NestedTitleAuthority)

    /// A focus level exists without its required ancestor level.
    case incompleteFocus(kind: NestedNodeKind)

    /// A focused descendant does not belong to the focused parent.
    case inconsistentFocus(child: NestedNodeID, parent: NestedNodeID)
}
