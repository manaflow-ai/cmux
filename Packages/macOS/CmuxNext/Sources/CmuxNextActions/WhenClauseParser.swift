/// Parses a `when` clause (plans/cmux-next/keybindings.md section 4, spec
/// K4). Not implemented yet.
public nonisolated struct WhenClauseParseError: Error, Equatable, Sendable {
    /// What is wrong (English; the editor shows a localized summary).
    public var message: String
    /// UTF-8 offset of the problem in the clause text.
    public var offset: Int
}

extension WhenClause {
    /// Parses `text`. Throws ``WhenClauseParseError``.
    public static func parse(_ text: String) throws(WhenClauseParseError) -> WhenClause {
        throw WhenClauseParseError(message: "not implemented", offset: 0)
    }
}
