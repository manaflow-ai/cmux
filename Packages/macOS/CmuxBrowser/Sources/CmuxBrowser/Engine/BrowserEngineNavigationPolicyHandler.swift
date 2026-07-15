/// Evaluates an engine-originated navigation before the browser commits it.
public typealias BrowserEngineNavigationPolicyHandler = @MainActor @Sendable (
    BrowserEngineNavigationRequest
) -> BrowserEngineNavigationDecision
