/// Whether two `when` clauses can hold at the same time (the editor's
/// conflicts: other entries on the same keys that may compete). The answer
/// is conservative: false only when the clauses provably exclude each other
/// (`x` and `!x`, `k == a` and `k == b`, `k == a` and `k != a`, two focus keys
/// that one focused surface never sets together, a clause that is always
/// false); anything it cannot prove, such as an `||`, may overlap.
extension WhenClause {
    public static func canOverlap(_ lhs: WhenClause?, _ rhs: WhenClause?) -> Bool {
        let left = lhs?.conjuncts ?? [], right = rhs?.conjuncts ?? []
        if left.contains(.constant(false)) || right.contains(.constant(false)) { return false }
        for a in left {
            for b in right where a.excludes(b) || b.excludes(a) { return false }
        }
        return true
    }

    /// Whether `lhs` holding means `rhs` holds: no `rhs`, or every `&&` term of `rhs` is one of
    /// `lhs`'s. Conservative: false when it cannot prove it. New keys on `rhs` take another
    /// binding's keys on `lhs` everywhere it runs only when this holds; else only where `rhs` does.
    public static func implies(_ lhs: WhenClause?, _ rhs: WhenClause?) -> Bool {
        guard let rhs else { return true }
        let terms = lhs?.conjuncts ?? []
        return rhs.conjuncts.allSatisfy { $0 == .constant(true) || terms.contains($0) }
    }

    /// The `&&` terms of this clause (itself when it is not an `&&`).
    nonisolated var conjuncts: [WhenClause] {
        if case .and(let clauses) = self { return clauses.flatMap(\.conjuncts) }
        return [self]
    }

    /// Whether this term and `other` cannot both hold.
    private func excludes(_ other: WhenClause) -> Bool {
        switch (self, other) {
        case (.has(let key), .not(.has(let negated))):
            return key == negated
        case (.has(let key), .has(let other)):
            return ActionContext.focusKeysExclude(key, other)
        case (.equals(let key, let value), .equals(let otherKey, let otherValue)):
            return key == otherKey && value.text != otherValue.text
        case (.equals(let key, let value), .notEquals(let otherKey, let otherValue)):
            return key == otherKey && value.text == otherValue.text
        default:
            return false
        }
    }
}
