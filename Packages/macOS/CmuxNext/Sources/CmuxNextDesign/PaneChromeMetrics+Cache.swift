/// ``PaneChromeMetrics/current`` is kept by `Metrics.memo.paneChrome` (`TokenMemo`) until an input changes. During a
/// live window resize the pane chrome read it about a thousand times a second: the other Mac's samples (2026-11-24,
/// in-tree OFF) put `PaneChromeMetrics.current` at about 21% of `ShellWindow.setFrame`, read from the tab strip's
/// inset, the top row's line, each pane's strip height and the corner chrome. The in-tree branch first cached it on
/// its own inputs; feat-cmux-next's `TokenMemo` (same samples' finding, 2026-11-22) now owns that cache for every
/// composite token, so this keeps only the count ``PaneChromeMetricsCacheTests`` reads.
extension PaneChromeMetrics {
    /// Memo misses: times ``current`` worked its value out (tests).
    @MainActor static var derivations = 0
}
