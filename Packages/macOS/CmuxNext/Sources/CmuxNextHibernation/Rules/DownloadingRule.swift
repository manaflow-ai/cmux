// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// A download the page started still runs; a discard would cancel it (lead rule).
    package static let downloading = DiscardRule(.downloading, result: .protected, for: DiscardRule.leadRule) { candidate, _ in
        candidate.isDownloading
    }
}
