// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// The content's `beforeunload` would ask before it unloads (lead rule).
    package static let beforeUnload = DiscardRule(.beforeUnload, result: .protected, for: DiscardRule.leadRule) { candidate, _ in
        candidate.asksBeforeUnload
    }
}
