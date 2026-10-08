import Foundation

/// A binding's `when` clause: a boolean expression over context keys
/// (plans/cmux-next/keybindings.md section 4). The operators are the
/// keybinding grammar's: `!`, `&&`, `||`, `==`, `!=`, `=~`, `in`.
public nonisolated indirect enum WhenClause: Hashable, Sendable {
    case constant(Bool)
    /// The key is set and truthy.
    case has(String)
    case not(WhenClause)
    case and([WhenClause])
    case or([WhenClause])
    /// The key's text equals the value's text. A missing key is not equal.
    case equals(String, KeyContextValue)
    /// The key's text differs from the value's text. A missing key differs.
    case notEquals(String, KeyContextValue)
    /// The key's text matches the regular expression.
    case matches(String, pattern: String)
    /// The key's text is an element of the list in `listKey`.
    case isIn(String, listKey: String)

    public func evaluate(_ context: KeyContext) -> Bool {
        switch self {
        case .constant(let value):
            return value
        case .has(let key):
            return context[key]?.isTruthy == true
        case .not(let clause):
            return !clause.evaluate(context)
        case .and(let clauses):
            return clauses.allSatisfy { $0.evaluate(context) }
        case .or(let clauses):
            return clauses.contains { $0.evaluate(context) }
        case .equals(let key, let value):
            return context[key]?.text == value.text
        case .notEquals(let key, let value):
            return context[key]?.text != value.text
        case .matches(let key, let pattern):
            guard let text = context[key]?.text, let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        case .isIn(let key, let listKey):
            guard let text = context[key]?.text, case .strings(let list)? = context[listKey] else { return false }
            return list.contains(text)
        }
    }

    /// The clause a catalog action's required context implies (every bit
    /// set), or nil when it requires nothing.
    public static func requiring(_ requires: ActionContext) -> WhenClause? {
        let keys = ActionContext.keyNames.filter { requires.contains($0.0) }.map { WhenClause.has($0.1) }
        switch keys.count {
        case 0: return nil
        case 1: return keys[0]
        default: return .and(keys)
        }
    }
}
