/// A `when` clause as keybindings.json text (the editor's When column,
/// `keybinding.list`): `WhenClause.parse(clause.text)` gives the clause back.
nonisolated extension WhenClause {
    public var text: String {
        switch self {
        case .constant(let value): value ? "true" : "false"
        case .has(let key): key
        case .not(.isIn(let key, let listKey)): "\(key) not in \(listKey)"
        case .not(let clause): "!" + clause.operand
        case .and(let clauses): clauses.map { if case .or = $0 { "(\($0.text))" } else { $0.text } }.joined(separator: " && ")
        case .or(let clauses): clauses.map(\.text).joined(separator: " || ")
        case .equals(let key, let value): "\(key) == \(Self.text(value))"
        case .notEquals(let key, let value): "\(key) != \(Self.text(value))"
        case .matches(let key, let pattern): "\(key) =~ \(Self.regex(pattern))"
        case .isIn(let key, let listKey): "\(key) in \(listKey)"
        }
    }

    /// The clause as the operand of `!`.
    private var operand: String {
        switch self {
        case .and, .or, .equals, .notEquals, .matches, .isIn, .not(.isIn): "(\(text))"
        default: text
        }
    }

    private static func text(_ value: KeyContextValue) -> String {
        switch value {
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number): return number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .strings(let list): return quoted(list.joined(separator: ","))
        case .string(let text):
            let bare = !text.isEmpty && text.utf8.allSatisfy(WhenClauseParser.isValueByte)
                && text != "true" && text != "false" && Double(text) == nil
            return bare ? text : quoted(text)
        }
    }

    private static func quoted(_ text: String) -> String {
        text.contains("'") ? "\"\(text)\"" : "'\(text)'"
    }

    private static func regex(_ pattern: String) -> String {
        let (body, flags) = pattern.hasPrefix("(?i)") ? (String(pattern.dropFirst(4)), "i") : (pattern, "")
        return "/" + body + "/" + flags
    }
}
