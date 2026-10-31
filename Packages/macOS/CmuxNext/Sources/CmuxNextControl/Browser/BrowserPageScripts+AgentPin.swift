import Foundation

extension BrowserPageScripts {
    /// Check the admitted document's origin in the same JavaScript turn that compiles the
    /// source. Encoding source as data prevents declarations or wrapper escapes from running
    /// before the check. An unknown origin has already reserved the entire profile against fills.
    static func pinnedAgentExpression(_ source: String, origin: String?) -> String {
        guard let origin else { return source }
        return "(() => { if (this.location.origin !== \(literal(origin))) throw new Error('cmux: page navigated before agent code'); return this.eval(\(literal(source))); })()"
    }

    /// Async wait bodies are compiled only after the pin, just like expression and statement
    /// evaluation. Each chunk is pinned independently, including chunks that follow navigation.
    static func pinnedAgentBody(_ body: String, origin: String?) -> String {
        guard origin != nil else { return body }
        let expression = "(async function() {\n\(body)\n}).call(this)"
        return "return await \(pinnedAgentExpression(expression, origin: origin));"
    }
}
