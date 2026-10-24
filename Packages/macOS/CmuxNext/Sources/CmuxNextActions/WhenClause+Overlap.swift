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

    /// Whether `lhs` holding means `rhs` holds, read over the clauses' shape: no `rhs`; every
    /// term of an `&&`; one branch of an `||`; an `lhs` `||` whose every branch does; or a term
    /// of `lhs` that is `rhs`. A binding on `lhs` never runs when a later binding on the same
    /// keys has `rhs` (the later entry wins), so the two conflict; a later binding on a narrower
    /// clause only takes the keys in its own context.
    public static func implies(_ lhs: WhenClause?, _ rhs: WhenClause?) -> Bool {
        guard let rhs else { return true }
        switch rhs {
        case .constant(true): return true
        case .and(let terms): return terms.allSatisfy { implies(lhs, $0) }
        case .or(let branches) where branches.contains(where: { implies(lhs, $0) }): return true
        default: break
        }
        guard let lhs else { return false }
        if case .or(let branches) = lhs { return branches.allSatisfy { implies($0, rhs) } }
        return lhs.conjuncts.contains { term in
            if term == rhs { return true }
            if case .or(let branches) = term { return branches.allSatisfy { implies($0, rhs) } }
            return false
        }
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
