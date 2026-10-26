// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// The content changed its title or icon while hidden (a count of unread mail, a chat's new
    /// message): the timeout keeps it, memory pressure does not. Chrome's `kBackgroundActivity`, which
    /// `DiscardEligibilityPolicy::CanDiscard` checks for proactive discards only
    /// (chrome/browser/performance_manager/policies/discard_eligibility_policy.cc). Showing the content
    /// clears the fact (``PageBackgroundActivity``).
    package static let backgroundActivity = DiscardRule(.backgroundActivity, result: .protected, for: [.proactive]) { candidate, _ in
        candidate.hasBackgroundActivity
    }
}
