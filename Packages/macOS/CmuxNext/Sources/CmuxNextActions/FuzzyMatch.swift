/// Convenience scorer for one-off matches. Higher is better; nil means no
/// match. Prepares both strings on every call, so hot paths (the palette)
/// build `FuzzyText` once and call `FuzzyMatcher` directly.
nonisolated public enum FuzzyMatch {
    public static func score(_ needle: String, in haystack: String) -> Int? {
        FuzzyMatcher.score(FuzzyQuery(needle), in: FuzzyText(haystack))
    }
}
