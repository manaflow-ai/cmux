// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// A discard of the content was tried and did not finish since it last showed
    /// (``ContentDiscardPlanner/AttemptMarkers``): no discard takes it, not even the person's own,
    /// until it shows again. Chrome's `kDiscardAttempted`
    /// (chrome/browser/performance_manager/policies/discard_eligibility_policy.cc), for every kind.
    package static let discardAttempted = DiscardRule(.discardAttempted, result: .disallowed, for: DiscardRule.always) { candidate, _ in
        candidate.discardAttempted
    }
}
