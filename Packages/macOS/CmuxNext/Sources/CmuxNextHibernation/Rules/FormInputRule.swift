// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// The person's edits sit in the content's form fields (Chrome's `kFormInteractions`). Chrome lets
    /// an urgent discard take it; cmux's lead rule does not.
    package static let formInput = DiscardRule(.formInput, result: .protected, for: DiscardRule.leadRule) { candidate, _ in
        candidate.hasFormInput
    }
}
