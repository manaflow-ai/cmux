// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// The content plays sound, media its mute silences, or Picture in Picture (Chrome's `kAudible`;
    /// lead rule).
    package static let audio = DiscardRule(.audio, result: .protected, for: DiscardRule.leadRule) { candidate, _ in
        candidate.isAudible
    }
}
