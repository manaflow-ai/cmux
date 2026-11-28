/// Result of waiting for a browser instance to commit its first automation document.
public enum BrowserAutomationDocumentReadinessOutcome: Sendable, Equatable {
    /// The observed browser instance committed a document and is ready for JavaScript automation.
    case committed

    /// A newer browser instance replaced the observed instance before it committed a document.
    case superseded

    /// The caller cancelled its wait before the observed instance committed a document.
    case cancelled
}
