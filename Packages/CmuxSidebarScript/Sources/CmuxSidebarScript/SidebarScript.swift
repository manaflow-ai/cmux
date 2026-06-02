import Foundation

/// A compiled sidebar script.
///
/// `init` parses the source and evaluates its top-level forms once (which should
/// `def` a `render-row` function and any helpers). `render(_:)` then calls
/// `render-row` with one row's data and returns a pure `RenderNode`.
///
/// The expensive parse + top-level evaluation happens once at load. Per-row
/// rendering is a single function application against a fresh evaluator, cheap
/// enough to run for visible rows and memoizable by the host on context
/// equality.
public final class SidebarScript {
    private let baseEnv: LispEnvironment

    /// The entry-point function name a script must define.
    public static let entryPoint = "render-row"

    public init(source: String) throws {
        let forms = try Reader().read(source)
        baseEnv = LispEnvironment()
        Builtins.install(into: baseEnv)
        Bridge.install(into: baseEnv)
        let evaluator = Evaluator()
        for form in forms {
            _ = try evaluator.eval(form, in: baseEnv)
        }
        guard baseEnv.lookup(Self.entryPoint) != nil else {
            throw LispError.eval(String(
                localized: "sidebarScript.error.missingEntry",
                defaultValue: "The script must define a 'render-row' function.",
                bundle: .module))
        }
    }

    /// Renders one row to a pure node tree. Throws a localized `LispError` if the
    /// script faults; the caller falls back to native rendering.
    public func render(_ context: SidebarScriptContext) throws -> RenderNode {
        guard let fn = baseEnv.lookup(Self.entryPoint) else {
            throw LispError.eval(String(
                localized: "sidebarScript.error.missingEntry",
                defaultValue: "The script must define a 'render-row' function.",
                bundle: .module))
        }
        let evaluator = Evaluator()
        let result = try evaluator.apply(fn, [context.lispValue])
        guard case .node(let node) = result else {
            throw LispError.eval(String(
                localized: "sidebarScript.error.entryReturn",
                defaultValue: "'render-row' must return a view, but returned a \(result.typeName).",
                bundle: .module))
        }
        return node
    }

    /// The bundled default script, used when the user has no `sidebar.lisp`.
    public static func defaultSource() -> String {
        guard let url = Bundle.module.url(forResource: "DefaultSidebar", withExtension: "lisp"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text
    }

    /// Convenience: compile the bundled default script.
    public static func makeDefault() throws -> SidebarScript {
        try SidebarScript(source: defaultSource())
    }
}
