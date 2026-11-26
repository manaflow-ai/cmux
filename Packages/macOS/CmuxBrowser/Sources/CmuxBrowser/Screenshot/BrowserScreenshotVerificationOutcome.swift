/// The conservative verification result for one browser screenshot.
public enum BrowserScreenshotVerificationOutcome: Equatable, Sendable {
    /// The snapshot is valid or the available evidence is inconclusive.
    case accepted

    /// Stable probes matched their backgrounds in at least the configured minimum
    /// number of distinct viewport cells.
    ///
    /// The associated probe identifies the first mismatching rectangle;
    /// `count` is the total number of mismatches found in the bounded set.
    case mismatch(probe: BrowserScreenshotProbe, count: Int)
}
