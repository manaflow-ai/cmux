/// The result of evaluating a browser-engine navigation request.
public enum BrowserEngineNavigationDecision: Sendable {
    /// Allow the engine to continue its original navigation.
    case allow

    /// Cancel the engine navigation before it commits.
    case cancel
}
