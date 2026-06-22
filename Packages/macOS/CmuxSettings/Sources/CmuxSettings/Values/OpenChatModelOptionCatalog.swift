import Foundation

/// Builds the Open Chat model picker from cmux's known agent catalog.
public struct OpenChatModelOptionCatalog: Sendable {
    /// Localized label used for the agent's configured default model.
    public let defaultModelLabel: String

    /// Creates a model option catalog.
    ///
    /// - Parameter defaultModelLabel: Localized label used for default model choices.
    public init(defaultModelLabel: String) {
        self.defaultModelLabel = defaultModelLabel
    }

    /// Returns model options for every backend/model combination cmux can drive.
    ///
    /// - Returns: Open Chat model picker options.
    public func options() -> [OpenChatModelOption] {
        directCodexOptions + directClaudeOptions + openCodeOptions
    }

    private var directCodexOptions: [OpenChatModelOption] {
        [
            directOption(provider: "codex", brand: "Codex", modelID: "gpt-5.5", label: "GPT-5.5", selected: true),
            directOption(provider: "codex", brand: "Codex", modelID: "gpt-5.1", label: "GPT-5.1"),
            directOption(provider: "codex", brand: "Codex", modelID: "gpt-5", label: "GPT-5"),
            directOption(provider: "codex", brand: "Codex", modelID: "gpt-4.1", label: "GPT-4.1"),
            directDefaultOption(provider: "codex", brand: "Codex"),
        ]
    }

    private var directClaudeOptions: [OpenChatModelOption] {
        [
            directDefaultOption(provider: "claude", brand: "Claude Code"),
            directOption(provider: "claude", brand: "Claude Code", modelID: "sonnet", label: "Sonnet"),
            directOption(provider: "claude", brand: "Claude Code", modelID: "opus", label: "Opus"),
            directOption(provider: "claude", brand: "Claude Code", modelID: "claude-sonnet-4-5", label: "Claude Sonnet 4.5"),
            directOption(provider: "claude", brand: "Claude Code", modelID: "claude-opus-4-1", label: "Claude Opus 4.1"),
        ]
    }

    private var openCodeOptions: [OpenChatModelOption] {
        [
            OpenChatModelOption(
                id: "opencode:default",
                label: "OpenCode - \(defaultModelLabel)",
                backendProviderID: "opencode",
                isSelected: false
            ),
            openCodeOption(provider: "anthropic", modelID: "claude-sonnet-4-5", label: "Anthropic Claude Sonnet 4.5"),
            openCodeOption(provider: "anthropic", modelID: "claude-opus-4-1", label: "Anthropic Claude Opus 4.1"),
            openCodeOption(provider: "openai", modelID: "gpt-5.5", label: "OpenAI GPT-5.5"),
            openCodeOption(provider: "openai", modelID: "gpt-5.1", label: "OpenAI GPT-5.1"),
            openCodeOption(provider: "openai", modelID: "gpt-4.1", label: "OpenAI GPT-4.1"),
            openCodeOption(provider: "google", modelID: "gemini-2.5-pro", label: "Google Gemini 2.5 Pro"),
            openCodeOption(provider: "google", modelID: "gemini-2.5-flash", label: "Google Gemini 2.5 Flash"),
            openCodeOption(provider: "xai", modelID: "grok-4", label: "xAI Grok 4"),
        ]
    }

    private func directDefaultOption(provider: String, brand: String) -> OpenChatModelOption {
        OpenChatModelOption(
            id: "\(provider):default",
            label: "\(brand) - \(defaultModelLabel)",
            backendProviderID: provider,
            isSelected: false
        )
    }

    private func directOption(
        provider: String,
        brand: String,
        modelID: String,
        label: String,
        selected: Bool = false
    ) -> OpenChatModelOption {
        OpenChatModelOption(
            id: "\(provider):\(modelID)",
            label: "\(brand) - \(label)",
            backendProviderID: provider,
            modelID: modelID,
            isSelected: selected
        )
    }

    private func openCodeOption(provider: String, modelID: String, label: String) -> OpenChatModelOption {
        OpenChatModelOption(
            id: "opencode:\(provider)/\(modelID)",
            label: "OpenCode - \(label)",
            backendProviderID: "opencode",
            modelID: modelID,
            openCodeProviderID: provider,
            isSelected: false
        )
    }
}
