/// Whether two `when` clauses can hold at the same time (the editor's
/// conflicts: other entries on the same keys that may compete). The answer
/// is conservative: false only when the clauses provably exclude each other
/// (`x` and `!x`, `k == a` and `k == b`, `k == a` and `k != a`, a clause that
/// is always false); anything it cannot prove, such as an `||`, may overlap.
extension WhenClause {
    public static func canOverlap(_ lhs: WhenClause?, _ rhs: WhenClause?) -> Bool {
        let left = lhs?.conjuncts ?? [], right = rhs?.conjuncts ?? []
        if left.contains(.constant(false)) || right.contains(.constant(false)) { return false }
        for a in left {
            for b in right where a.excludes(b) || b.excludes(a) { return false }
        }
        return true
    }

    /// The `&&` terms of this clause (itself when it is not an `&&`).
    private var conjuncts: [WhenClause] {
        if case .and(let clauses) = self { return clauses.flatMap(\.conjuncts) }
        return [self]
    }

    /// Whether this term and `other` cannot both hold.
    private func excludes(_ other: WhenClause) -> Bool {
        switch (self, other) {
        case (.has(let key), .not(.has(let negated))):
            return key == negated
        case (.equals(let key, let value), .equals(let otherKey, let otherValue)):
            return key == otherKey && value.text != otherValue.text
        case (.equals(let key, let value), .notEquals(let otherKey, let otherValue)):
            return key == otherKey && value.text == otherValue.text
        default:
            return false
        }
    }
}
