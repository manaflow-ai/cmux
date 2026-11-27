/// A `when` clause as keybindings.json text (the editor's When column,
/// `keybinding.list`): `WhenClause.parse(clause.text)` gives the clause back.
/// The printer lives in Rust (cmux-action-catalog `when_clause`, op `when_text`).
nonisolated extension WhenClause {
    public var text: String {
        ActionCatalogRust.call(["op": "when_text", "clause": tree])?["text"] as? String ?? ""
    }
}
