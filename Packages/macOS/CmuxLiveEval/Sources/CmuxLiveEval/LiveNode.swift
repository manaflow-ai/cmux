import CmuxSwiftRender
import SwiftSyntax

/// One shallow level of evaluated interpreted view structure.
///
/// Unlike the snapshot pipeline's `RenderNode`, a `LiveNode` is ephemeral and
/// deliberately *not* deep. Containers carry their children as an unevaluated
/// ``LiveBlock`` so evaluating a parent never reads child state. Each nesting
/// level is evaluated by its own native view, preserving per-subtree
/// invalidation granularity.
@MainActor
public enum LiveNode {
    case text(String)
    case button(title: String, action: @MainActor () -> Void)
    case textField(placeholder: String, text: LiveValueBinding<String>)
    case toggle(title: String, isOn: LiveValueBinding<Bool>)
    case stack(axis: LiveStackAxis, spacing: Double?, content: LiveBlock)
    case forEach(rows: [LiveForEachRow])
    case spacer
    case divider
    case empty
}

/// Stack orientation for ``LiveNode/stack(axis:spacing:content:)``.
public enum LiveStackAxis: Sendable {
    case vertical
    case horizontal
    case depth
}

/// An unevaluated builder block: raw statements plus their evaluation scope.
@MainActor
public struct LiveBlock {
    public let statements: [CodeBlockItemSyntax]
    public let scope: LiveScope

    public init(statements: [CodeBlockItemSyntax], scope: LiveScope) {
        self.statements = statements
        self.scope = scope
    }
}

/// One row of an interpreted `ForEach`: a stable identity (from the `id:`
/// argument or the element itself) plus the row's unevaluated block.
public struct LiveForEachRow: Identifiable {
    public let id: String
    public let content: LiveBlock

    public init(id: String, content: LiveBlock) {
        self.id = id
        self.content = content
    }
}
