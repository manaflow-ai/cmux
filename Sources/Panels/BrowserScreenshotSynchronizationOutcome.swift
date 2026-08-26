/// Result of the bounded preparation step before a browser snapshot.
enum BrowserScreenshotSynchronizationOutcome: Equatable, Sendable {
    /// WebKit acknowledged the requested layout or animation-frame barrier.
    case completed
    /// The barrier was not confirmed, so any later pixel disagreement is inconclusive.
    case unconfirmed
}
