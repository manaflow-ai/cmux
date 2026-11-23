/// A `when` clause as keybindings.json text (the editor's When column,
/// `keybinding.list`): `WhenClause.parse(clause.text)` gives the clause back. Formatted in Rust
/// (cmux-action-catalog `when_clause`).
nonisolated extension WhenClause {
    public var text: String {
        RustCatalogCall.reply(["op": "when_text", "clause": node])?["text"] as? String ?? ""
    }
}
