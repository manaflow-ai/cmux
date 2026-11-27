import Foundation

/// A comparison operator in a ``ShortcutWhenClause`` `.compare` term.
///
/// Modeled on VS Code's `when`-clause operators. The operand type each operator
/// accepts is enforced when parsing (see ``ShortcutContextOperand``):
///
/// - ``equals`` / ``notEquals`` accept a string or integer operand.
/// - ``lessThan`` / ``lessThanOrEqual`` / ``greaterThan`` / ``greaterThanOrEqual``
///   require an integer operand.
/// - ``matches`` requires a `/.../` regular-expression operand.
/// - ``inList`` requires a bracketed list operand.
public enum ShortcutComparisonOperator: String, CaseIterable, Sendable, Equatable {
    /// `==` — the context value equals the operand.
    case equals = "=="
    /// `!=` — the context value differs from the operand.
    case notEquals = "!="
    /// `=~` — the context's string value matches the operand regular expression.
    case matches = "=~"
    /// `<` — the context's integer value is less than the operand.
    case lessThan = "<"
    /// `<=` — the context's integer value is at most the operand.
    case lessThanOrEqual = "<="
    /// `>` — the context's integer value is greater than the operand.
    case greaterThan = ">"
    /// `>=` — the context's integer value is at least the operand.
    case greaterThanOrEqual = ">="
    /// `in` — the context value is a member of the operand list.
    case inList = "in"
}
