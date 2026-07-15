/// A pre-commit decision for an engine-originated browser navigation.
public enum BrowserEngineNavigationDecision: Sendable {
    /// Allow the browser engine to continue the original navigation.
    case allow

    /// Cancel the browser engine's original navigation.
    case cancel
}
