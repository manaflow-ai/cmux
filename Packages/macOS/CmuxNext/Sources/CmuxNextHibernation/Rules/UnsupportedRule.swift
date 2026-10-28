// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// The engine cannot save and restore the content's history, so a discard would lose it, even one
    /// the person asks for.
    package static let unsupported = DiscardRule(.unsupported, result: .disallowed, for: DiscardRule.always) { candidate, _ in
        !candidate.canRestore
    }
}
