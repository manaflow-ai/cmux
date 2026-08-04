/// The rendered node tree and runtime data-member coverage from one
/// interpreted sidebar evaluation.
///
/// Use this result when validating authored source rather than rendering it:
/// ``accessedMemberNames`` identifies data members the executed path read, so
/// a validator can compare representative states and detect inputs that have
/// no effect on the rendered tree.
public struct SwiftViewEvaluation: Sendable {
    /// The interpreted view tree, or `nil` when no supported view was produced.
    public let node: RenderNode?

    /// Member names read while evaluating the executed source path.
    public let accessedMemberNames: Set<String>

    init(node: RenderNode?, accessedMemberNames: Set<String>) {
        self.node = node
        self.accessedMemberNames = accessedMemberNames
    }
}
