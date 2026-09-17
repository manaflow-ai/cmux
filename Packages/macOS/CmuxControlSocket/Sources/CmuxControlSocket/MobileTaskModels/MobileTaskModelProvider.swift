/// Coding-agent providers supported by mobile task model discovery.
public enum MobileTaskModelProvider: String, CaseIterable, Sendable {
    /// Anthropic's Claude Code CLI.
    case claude
    /// OpenAI's Codex CLI.
    case codex
    /// The OpenCode CLI.
    case openCode = "opencode"

    /// Curated fallback models in composer display order.
    public var curatedModels: [MobileTaskModel] {
        switch self {
        case .claude:
            [
                MobileTaskModel(id: "claude-fable-5", displayName: "Fable 5"),
                MobileTaskModel(id: "claude-opus-4-8", displayName: "Opus 4.8"),
                MobileTaskModel(id: "claude-sonnet-5", displayName: "Sonnet 5"),
                MobileTaskModel(id: "claude-haiku-4-5", displayName: "Haiku 4.5"),
            ]
        case .codex:
            [
                MobileTaskModel(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna"),
                MobileTaskModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol"),
                MobileTaskModel(id: "gpt-5.5", displayName: "GPT-5.5"),
            ]
        case .openCode:
            [
                MobileTaskModel(
                    id: "anthropic/claude-sonnet-5",
                    displayName: "Claude Sonnet 5"
                ),
                MobileTaskModel(
                    id: "anthropic/claude-opus-4-8",
                    displayName: "Claude Opus 4.8"
                ),
                MobileTaskModel(id: "openai/gpt-5.5", displayName: "GPT-5.5"),
            ]
        }
    }

    /// Returns the curated display name for an identifier when one exists.
    ///
    /// - Parameter id: Provider model identifier.
    /// - Returns: Curated display name, or the raw identifier for a novel model.
    public func displayName(for id: String) -> String {
        curatedModels.first { $0.id == id }?.displayName ?? id
    }
}
