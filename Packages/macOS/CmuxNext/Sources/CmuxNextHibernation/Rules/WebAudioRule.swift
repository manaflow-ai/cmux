// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// A running Web Audio context. It may be silent, but only the page knows whether it is heard, so
    /// it counts as audio at every pressure (lead rule).
    package static let webAudio = DiscardRule(.webAudio, result: .protected, for: DiscardRule.leadRule) { candidate, _ in
        candidate.usesWebAudio
    }
}
