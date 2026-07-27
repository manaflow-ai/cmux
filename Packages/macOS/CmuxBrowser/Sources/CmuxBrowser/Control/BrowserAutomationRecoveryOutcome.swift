/// Result of checking whether a browser automation callback pipeline is alive.
public enum BrowserAutomationRecoveryOutcome: Sendable, Equatable {
    /// The liveness callback arrived before the deadline, so the current WebView remains authoritative.
    case responsive

    /// The callback missed its deadline and the owning browser surface replaced the unresponsive WebView.
    case recovered

    /// The callback missed its deadline, but another lifecycle path had already replaced the observed WebView.
    case superseded

    /// The check was cancelled before liveness or timeout produced an outcome.
    case cancelled
}
