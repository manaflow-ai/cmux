// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// The content did not answer its probe, so its edits are unknown. The timeout always keeps it;
    /// memory pressure only while it still gets the benefit of the doubt (`PageProbeHistory`).
    package static let unanswered = DiscardRule(.unanswered, result: .protected, for: DiscardRule.leadRule) { candidate, context in
        candidate.isUnanswered && (candidate.isDoubted || context.reason == .proactive)
    }
}
