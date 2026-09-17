import Foundation

/// The right-hand operand of a ``ShortcutWhenClause`` `.compare` term.
///
/// The operand kind a comparison accepts depends on its
/// ``ShortcutComparisonOperator``:
///
/// - ``ShortcutComparisonOperator/equals`` / ``ShortcutComparisonOperator/notEquals``
///   accept ``string(_:)`` or ``int(_:)``.
/// - The relational operators accept ``int(_:)``.
/// - ``ShortcutComparisonOperator/matches`` accepts ``regex(_:)``.
/// - ``ShortcutComparisonOperator/inList`` accepts ``list(_:)``.
public indirect enum ShortcutContextOperand: Equatable, Sendable {
    /// A single-quoted (`'find'`) or bareword (`find`) string literal.
    case string(String)
    /// An integer literal.
    case int(Int)
    /// A `/.../` regular-expression literal.
    case regex(ShortcutRegex)
    /// A bracketed list of literals, for the `in` operator.
    case list([ShortcutContextOperand])
}
