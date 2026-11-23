/// Parses a `when` clause (plans/cmux-next/keybindings.md section 4, spec
/// K4): `!`, `&&`, `||`, `==`, `!=`, `=~`, `in`, `not in`, parentheses,
/// `true`, `false`, context keys and values (quoted, bare or numeric;
/// `=~` takes `/regex/` with an optional `i` flag). `&&` binds tighter than
/// `||`. A parse error disables only the entry that holds the clause.
public nonisolated struct WhenClauseParseError: Error, Equatable, Sendable {
    /// What is wrong (English; the editor shows a localized summary).
    public var message: String
    /// UTF-8 offset of the problem in the clause text.
    public var offset: Int
}

extension WhenClause {
    /// Parses `text` (in Rust, cmux-action-catalog `when_clause`). Throws ``WhenClauseParseError``.
    public nonisolated static func parse(_ text: String) throws(WhenClauseParseError) -> WhenClause {
        guard let reply = RustCatalogCall.reply(["op": "when_parse", "text": text]) else {
            throw WhenClauseParseError(message: "the clause parser did not answer", offset: 0)
        }
        if let error = reply["error"] as? [String: Any] {
            throw WhenClauseParseError(message: error["message"] as? String ?? "", offset: error["offset"] as? Int ?? 0)
        }
        guard let clause = reply["clause"].flatMap(WhenClause.init(node:)) else {
            throw WhenClauseParseError(message: "the clause parser did not answer", offset: 0)
        }
        return clause
    }

    /// The clause a `when_parse` tree node holds (`{"has":"k"}`, `{"and":[…]}`, …), nil when it is not one.
    nonisolated init?(node: Any) {
        guard let object = node as? [String: Any], let entry = object.first else { return nil }
        let (tag, body) = (entry.key, entry.value)
        func pair() -> (key: String, value: Any)? {
            guard let items = body as? [Any], items.count == 2, let key = items[0] as? String else { return nil }
            return (key, items[1])
        }
        func list() -> [WhenClause]? {
            guard let items = body as? [Any] else { return nil }
            let clauses = items.compactMap { WhenClause(node: $0) }
            return clauses.count == items.count ? clauses : nil
        }
        switch tag {
        case "const": guard let value = body as? Bool else { return nil }; self = .constant(value)
        case "has": guard let key = body as? String else { return nil }; self = .has(key)
        case "not": guard let inner = WhenClause(node: body) else { return nil }; self = .not(inner)
        case "and": guard let clauses = list() else { return nil }; self = .and(clauses)
        case "or": guard let clauses = list() else { return nil }; self = .or(clauses)
        case "eq": guard let operands = pair(), let value = KeyContextValue(node: operands.value) else { return nil }; self = .equals(operands.key, value)
        case "ne": guard let operands = pair(), let value = KeyContextValue(node: operands.value) else { return nil }; self = .notEquals(operands.key, value)
        case "match": guard let operands = pair(), let pattern = operands.value as? String else { return nil }; self = .matches(operands.key, pattern: pattern)
        case "in": guard let operands = pair(), let list = operands.value as? String else { return nil }; self = .isIn(operands.key, listKey: list)
        default: return nil
        }
    }

    /// The clause as a `when_text` tree node (the inverse of ``init(node:)``).
    nonisolated var node: [String: Any] {
        switch self {
        case .constant(let value): ["const": value]
        case .has(let key): ["has": key]
        case .not(let clause): ["not": clause.node]
        case .and(let clauses): ["and": clauses.map(\.node)]
        case .or(let clauses): ["or": clauses.map(\.node)]
        case .equals(let key, let value): ["eq": [key, value.node]]
        case .notEquals(let key, let value): ["ne": [key, value.node]]
        case .matches(let key, let pattern): ["match": [key, pattern]]
        case .isIn(let key, let listKey): ["in": [key, listKey]]
        }
    }
}

extension KeyContextValue {
    /// The value a tree node holds (`{"bool":…}`, `{"number":…}`, `{"string":…}`, `{"strings":[…]}`).
    nonisolated init?(node: Any) {
        guard let object = node as? [String: Any], let entry = object.first else { return nil }
        let (tag, body) = (entry.key, entry.value)
        switch tag {
        case "bool": guard let flag = body as? Bool else { return nil }; self = .bool(flag)
        case "number":
            // Not finite: Rust sends the text ("inf", "nan"), which JSON has no number for.
            if let text = body as? String, let number = Double(text) { self = .number(number) }
            else if let number = body as? Double { self = .number(number) }
            else { return nil }
        case "string": guard let text = body as? String else { return nil }; self = .string(text)
        case "strings": guard let list = body as? [String] else { return nil }; self = .strings(list)
        default: return nil
        }
    }

    /// The value as a tree node; a number that is not finite goes as its text.
    nonisolated var node: [String: Any] {
        switch self {
        case .bool(let flag): ["bool": flag]
        case .number(let number): ["number": number.isFinite ? number as Any : String(number) as Any]
        case .string(let text): ["string": text]
        case .strings(let list): ["strings": list]
        }
    }
}
