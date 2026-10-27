// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// An agent holds the page's browser lease: its cursor is on the page and its next call needs it
    /// (Chrome's `kGlicShared`, which cmux keeps from pressure too).
    package static let agentLease = DiscardRule(.agentLease, result: .protected, for: DiscardRule.leadRule) { candidate, _ in
        candidate.hasAgentLease
    }
}
