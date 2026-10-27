// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// The content holds edits the person has not saved (Chrome's `kUserEdits`; lead rule, as form
    /// input).
    package static let unsavedEdits = DiscardRule(.unsavedEdits, result: .protected, for: DiscardRule.leadRule) { candidate, _ in
        candidate.hasUnsavedEdits
    }
}
