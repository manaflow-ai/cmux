import Testing
@testable import CmuxSidebarScript

/// Evaluates a source string against a fresh environment with the full standard
/// library + SwiftUI bridge installed, returning the value of the last form.
func run(_ source: String) throws -> LispValue {
    let forms = try Reader().read(source)
    let env = LispEnvironment()
    Builtins.install(into: env)
    Bridge.install(into: env)
    let ev = Evaluator()
    var result: LispValue = .null
    for form in forms { result = try ev.eval(form, in: env) }
    return result
}

extension RenderNode {
    /// Depth-first search for the first descendant (or self) with `kind`.
    func firstNode(kind: String) -> RenderNode? {
        if self.kind == kind { return self }
        for child in children {
            if let found = child.firstNode(kind: kind) { return found }
        }
        return nil
    }

    /// All descendant nodes (including self) with `kind`.
    func nodes(kind: String) -> [RenderNode] {
        var out: [RenderNode] = []
        if self.kind == kind { out.append(self) }
        for child in children { out.append(contentsOf: child.nodes(kind: kind)) }
        return out
    }

    func modifier(_ name: String) -> RenderModifier? {
        modifiers.first { $0.name == name }
    }

    /// Whether any descendant text node renders exactly `value`.
    func containsText(_ value: String) -> Bool {
        nodes(kind: "text").contains { $0.content["text"]?.string == value }
    }

    func containsTextContaining(_ value: String) -> Bool {
        nodes(kind: "text").contains { ($0.content["text"]?.string ?? "").contains(value) }
    }
}

extension LispValue {
    var asNode: RenderNode? {
        if case .node(let n) = self { return n }
        return nil
    }
}
