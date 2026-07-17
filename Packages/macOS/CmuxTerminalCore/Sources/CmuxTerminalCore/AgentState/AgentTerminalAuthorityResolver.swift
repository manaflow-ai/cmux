/// Resolves lifecycle authority without allowing screen evidence to compete.
public struct AgentTerminalAuthorityResolver: Sendable {
    /// Creates a stateless authority resolver.
    public init() {}

    /// Resolves one family's lifecycle and screen reports.
    ///
    /// Complete integrations own state whenever present. Session-only
    /// integrations remain a fallback because their events do not describe
    /// every terminal interaction state.
    public func resolve(
        authoritative: AgentTerminalSemanticState?,
        screen: AgentTerminalSemanticState?,
        lifecycleAuthoritative: Bool = true
    ) -> AgentTerminalSemanticState {
        if lifecycleAuthoritative { return authoritative ?? screen ?? .unknown }
        return screen ?? authoritative ?? .unknown
    }
}
