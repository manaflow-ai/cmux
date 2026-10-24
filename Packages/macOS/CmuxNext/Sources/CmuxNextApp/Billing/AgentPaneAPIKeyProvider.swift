import CmuxNextCodeRouter

/// Which provider's API key a harness family takes, and the variable acpmux hands the key in
/// (routes.rs: Claude Code reads `ANTHROPIC_API_KEY`; Codex, OpenCode and Pi read `OPENAI_API_KEY`
/// on an OpenAI-shaped route). Nil for a family no direct key route serves (Gemini CLI, UniiChat).
nonisolated struct AgentPaneAPIKeyProvider: Equatable, Sendable {
    let provider: AIProvider
    let environmentKey: String

    init?(family: String) {
        switch family {
        case "claude": self.init(provider: .anthropic, environmentKey: "ANTHROPIC_API_KEY")
        case "codex", "opencode", "pi": self.init(provider: .openAI, environmentKey: "OPENAI_API_KEY")
        default: return nil
        }
    }

    private init(provider: AIProvider, environmentKey: String) {
        self.provider = provider
        self.environmentKey = environmentKey
    }

    /// The acpmux route that sends this provider's key (`apikey-anthropic`).
    var routeID: String { "apikey-\(provider.rawValue)" }
}
