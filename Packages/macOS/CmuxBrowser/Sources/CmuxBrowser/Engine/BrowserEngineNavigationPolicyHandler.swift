/// Evaluates an engine-originated navigation on cmux's main actor.
public typealias BrowserEngineNavigationPolicyHandler = @MainActor @Sendable (
    BrowserEngineNavigationRequest
) -> BrowserEngineNavigationDecision
