// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// The page shows the result of a form POST (BR-R1): restoring it would send the form again or
    /// show an error, so no discard takes it.
    package static let formSubmission = DiscardRule(.formSubmission, result: .disallowed, for: DiscardRule.always,
                                                    kinds: DiscardRule.browserPages) { candidate, _ in
        candidate.showsFormSubmission
    }
}
