/// The terminal result of one browser-automation navigation transaction.
public enum BrowserAutomationNavigationOutcome: Sendable, Equatable {
    /// The exact navigation started for the transaction committed a document.
    case committed

    /// WebKit reported a terminal navigation failure.
    case failed(String)

    /// WebKit cancelled the provisional navigation before it committed.
    case cancelled

    /// A newer automation navigation or WebView instance replaced this transaction.
    case superseded

    /// WebKit declined to create a navigation for the requested load.
    case notStarted

    /// No terminal delegate callback arrived before the bounded navigation deadline.
    case timedOut
}
