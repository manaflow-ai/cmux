import Foundation

extension BrowserPageScripts {
    /// Check the admitted document's origin before agent statements in the same native
    /// evaluation. This is a Program, with no enclosing function for source to escape.
    /// Throw a literal so a hoisted Error declaration cannot execute at the guard.
    static func pinnedAgentExpression(_ source: String, origin: String?) -> String {
        guard let origin else { return source }
        return "if (this.location.origin !== \(literal(origin))) throw 'cmux: page navigated before agent code';\n\(source)"
    }

    /// Each wait chunk is pinned independently. The WebKit async boundary validates the
    /// complete FunctionBody before wrapping it, preventing code outside this guard.
    static func pinnedAgentBody(_ body: String, origin: String?) -> String {
        pinnedAgentExpression(body, origin: origin)
    }
}
