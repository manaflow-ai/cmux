// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// The person moved into a child frame whose fields cannot be read: its edits count as the
    /// person's input (lead rule).
    package static let unreadableFrame = DiscardRule(.unreadableFrame, result: .protected, for: DiscardRule.leadRule) { candidate, _ in
        candidate.hasUnreadableFrame
    }
}
