import Foundation

/// Parses a `when` clause (plans/cmux-next/keybindings.md section 4, spec
/// K4): `!`, `&&`, `||`, `==`, `!=`, `=~`, `in`, `not in`, parentheses,
/// `true`, `false`, context keys and values (quoted, bare or numeric;
/// `=~` takes `/regex/` with an optional `i` flag). `&&` binds tighter than
/// `||`. A parse error disables only the entry that holds the clause. The
/// grammar lives in Rust (cmux-action-catalog `when_clause`, op `when_parse`).
public nonisolated struct WhenClauseParseError: Error, Equatable, Sendable {
    /// What is wrong (English; the editor shows a localized summary).
    public var message: String
    /// UTF-8 offset of the problem in the clause text.
    public var offset: Int
}

extension WhenClause {
    /// Parses `text`. Throws ``WhenClauseParseError``.
    public nonisolated static func parse(_ text: String) throws(WhenClauseParseError) -> WhenClause {
        let reply = ActionCatalogRust.call(["op": "when_parse", "text": text])
        if let clause = reply?["clause"].flatMap(WhenClause.init(tree:)) { return clause }
        let error = reply?["error"] as? [String: Any]
        throw WhenClauseParseError(message: error?["message"] as? String ?? "the clause did not parse",
                                   offset: error?["offset"] as? Int ?? 0)
    }
}

nonisolated extension WhenClause {
    /// The clause a Rust tree node holds, nil when it is not one.
    init?(tree: Any) {
        guard let node = tree as? [String: Any], node.count == 1, let (tag, body) = node.first else { return nil }
        let pair = body as? [Any]
        let key = pair?.first as? String
        switch tag {
        case "const": guard let value = body as? Bool else { return nil }; self = .constant(value)
        case "has": guard let key = body as? String else { return nil }; self = .has(key)
        case "not": guard let inner = WhenClause(tree: body) else { return nil }; self = .not(inner)
        case "and", "or":
            guard let items = body as? [Any] else { return nil }
            let clauses = items.compactMap(WhenClause.init(tree:))
            guard clauses.count == items.count else { return nil }
            self = tag == "and" ? .and(clauses) : .or(clauses)
        case "eq", "ne":
            guard let key, pair?.count == 2, let value = pair.flatMap({ KeyContextValue(tree: $0[1]) }) else { return nil }
            self = tag == "eq" ? .equals(key, value) : .notEquals(key, value)
        case "match", "in":
            guard let key, pair?.count == 2, let other = pair?[1] as? String else { return nil }
            self = tag == "match" ? .matches(key, pattern: WhenPattern(other)) : .isIn(key, listKey: other)
        default: return nil
        }
    }

    /// The clause as a Rust tree node.
    var tree: [String: Any] {
        switch self {
        case .constant(let value): ["const": value]
        case .has(let key): ["has": key]
        case .not(let clause): ["not": clause.tree]
        case .and(let clauses): ["and": clauses.map(\.tree)]
        case .or(let clauses): ["or": clauses.map(\.tree)]
        case .equals(let key, let value): ["eq": [key, value.tree] as [Any]]
        case .notEquals(let key, let value): ["ne": [key, value.tree] as [Any]]
        case .matches(let key, let pattern): ["match": [key, pattern.text]]
        case .isIn(let key, let listKey): ["in": [key, listKey]]
        }
    }
}

nonisolated extension KeyContextValue {
    init?(tree: Any) {
        guard let node = tree as? [String: Any], node.count == 1, let (tag, body) = node.first else { return nil }
        switch tag {
        case "bool": guard let flag = body as? Bool else { return nil }; self = .bool(flag)
        case "number":
            if let text = body as? String {
                switch text {
                case "inf": self = .number(.infinity)
                case "-inf": self = .number(-.infinity)
                case "nan": self = .number(.nan)
                default: return nil
                }
            } else if let number = body as? Double { self = .number(number) } else { return nil }
        case "string": guard let text = body as? String else { return nil }; self = .string(text)
        case "strings": guard let list = body as? [String] else { return nil }; self = .strings(list)
        default: return nil
        }
    }

    var tree: [String: Any] {
        switch self {
        case .bool(let flag): ["bool": flag]
        case .number(let number) where number.isNaN: ["number": "nan"]
        case .number(let number) where number.isInfinite: ["number": number < 0 ? "-inf" : "inf"]
        case .number(let number): ["number": number]
        case .string(let text): ["string": text]
        case .strings(let list): ["strings": list]
        }
    }
}
