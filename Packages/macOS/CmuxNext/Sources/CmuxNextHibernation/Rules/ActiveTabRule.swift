// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// The page a pane shows while its window is off screen (minimized, another Space, covered, the
    /// app hidden or the displays asleep): Chrome's `kActiveTab` (discard_eligibility_policy.cc),
    /// which keeps each window's active tab from the timeout and from memory pressure, so the
    /// window never comes back to pages that all reload together.
    package static let activeTab = DiscardRule(.activeTab, result: .protected, for: DiscardRule.pressure,
                                               kinds: DiscardRule.browserPages) { candidate, _ in
        candidate.isActiveTab
    }
}
