import CmuxSwiftRender
import SwiftSyntax
import SwiftUI

/// One shallow level of evaluated interpreted view structure.
///
/// Unlike the snapshot pipeline's `RenderNode`, a `LiveNode` is ephemeral and
/// deliberately *not* deep: containers carry their children as an unevaluated
/// ``LiveBlock`` (AST + scope), so evaluating a parent never reads the state
/// its children depend on. Each nesting level is evaluated inside its own
/// compiled stub view's body, which is what gives SwiftUI per-subtree
/// invalidation granularity.
public enum LiveNode {
    case text(String)
    case button(title: String, action: @MainActor () -> Void)
    case textField(placeholder: String, text: Binding<String>)
    case toggle(title: String, isOn: Binding<Bool>)
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

/// An unevaluated ViewBuilder block: raw statements plus the scope they will
/// evaluate in. Rendering hosts each block in a compiled stub view whose body
/// performs the (tracked) evaluation.
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
