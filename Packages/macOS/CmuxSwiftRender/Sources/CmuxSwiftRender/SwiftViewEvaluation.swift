/// The rendered node tree and runtime data-member coverage from one
/// interpreted sidebar evaluation.
///
/// Use this result when validating authored source rather than rendering it.
/// ``accessedTrackedMemberNames`` identifies members read directly from the
/// base values selected by the caller, so a validator can compare
/// representative states without conflating nested objects that reuse a field
/// name.
public struct SwiftViewEvaluation: Sendable {
    /// The interpreted view tree, or `nil` when no supported view was produced.
    public let node: RenderNode?

    /// Member names read directly from caller-selected base values.
    public let accessedTrackedMemberNames: Set<String>

    /// Creates an evaluation result from a rendered node and tracked member reads.
    init(node: RenderNode?, accessedTrackedMemberNames: Set<String>) {
        self.node = node
        self.accessedTrackedMemberNames = accessedTrackedMemberNames
    }
}
