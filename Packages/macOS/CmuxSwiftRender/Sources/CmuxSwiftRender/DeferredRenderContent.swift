/// A view-builder payload that is retained without evaluating its body.
///
/// SwiftUI's menu APIs accept an escaping content builder and do not ask for
/// that content while the row itself is being rendered. Keeping the builder as
/// an immutable payload lets the interpreter preserve that boundary instead of
/// expanding every menu on every sidebar refresh.
///
/// The unchecked conformance is safe because the captured syntax and
/// environment are read-only after the interpreter returns; each invocation
/// snapshots the environment into a fresh scope before mutating it locally.
struct DeferredRenderContent: @unchecked Sendable {
    private let builder: () -> [RenderNode]

    init(builder: @escaping () -> [RenderNode]) {
        self.builder = builder
    }

    /// Evaluates the payload when the surrounding menu asks for its body.
    func materialize() -> [RenderNode] {
        builder()
    }
}
