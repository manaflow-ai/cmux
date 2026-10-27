// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// A terminal's command still runs: its output would be lost.
    package static let runningCommand = DiscardRule(.runningCommand, result: .protected, for: DiscardRule.leadRule) { candidate, _ in
        candidate.runsCommand
    }
}
