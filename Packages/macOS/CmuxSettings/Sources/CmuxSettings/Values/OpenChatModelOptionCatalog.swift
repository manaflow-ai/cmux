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
            directOption(provider: "codex", brand: codexBrand, modelID: "gpt-5.5", label: gpt55Label, selected: true),
            directOption(provider: "codex", brand: codexBrand, modelID: "gpt-5.1", label: gpt51Label),
            directOption(provider: "codex", brand: codexBrand, modelID: "gpt-5", label: gpt5Label),
            directOption(provider: "codex", brand: codexBrand, modelID: "gpt-4.1", label: gpt41Label),
            directDefaultOption(provider: "codex", brand: codexBrand),
        ]
    }

    private var directClaudeOptions: [OpenChatModelOption] {
        [
            directDefaultOption(provider: "claude", brand: claudeCodeBrand),
            directOption(provider: "claude", brand: claudeCodeBrand, modelID: "sonnet", label: sonnetLabel),
            directOption(provider: "claude", brand: claudeCodeBrand, modelID: "opus", label: opusLabel),
            directOption(provider: "claude", brand: claudeCodeBrand, modelID: "claude-sonnet-4-5", label: claudeSonnet45Label),
            directOption(provider: "claude", brand: claudeCodeBrand, modelID: "claude-opus-4-1", label: claudeOpus41Label),
        ]
    }

    private var openCodeOptions: [OpenChatModelOption] {
        [
            OpenChatModelOption(
                id: "opencode:default",
                label: combinedLabel(openCodeBrand, defaultModelLabel),
                backendProviderID: "opencode",
                isSelected: false
            ),
            openCodeOption(provider: "anthropic", modelID: "claude-sonnet-4-5", label: anthropicClaudeSonnet45Label),
            openCodeOption(provider: "anthropic", modelID: "claude-opus-4-1", label: anthropicClaudeOpus41Label),
            openCodeOption(provider: "openai", modelID: "gpt-5.5", label: openAIGPT55Label),
            openCodeOption(provider: "openai", modelID: "gpt-5.1", label: openAIGPT51Label),
            openCodeOption(provider: "openai", modelID: "gpt-4.1", label: openAIGPT41Label),
            openCodeOption(provider: "google", modelID: "gemini-2.5-pro", label: googleGemini25ProLabel),
            openCodeOption(provider: "google", modelID: "gemini-2.5-flash", label: googleGemini25FlashLabel),
            openCodeOption(provider: "xai", modelID: "grok-4", label: xAIGrok4Label),
        ]
    }

    private var codexBrand: String {
        String(localized: "openChat.modelOption.codexBrand", defaultValue: "Codex")
    }

    private var claudeCodeBrand: String {
        String(localized: "openChat.modelOption.claudeCodeBrand", defaultValue: "Claude Code")
    }

    private var openCodeBrand: String {
        String(localized: "openChat.modelOption.openCodeBrand", defaultValue: "OpenCode")
    }

    private var gpt55Label: String {
        String(localized: "openChat.modelOption.gpt55", defaultValue: "GPT-5.5")
    }

    private var gpt51Label: String {
        String(localized: "openChat.modelOption.gpt51", defaultValue: "GPT-5.1")
    }

    private var gpt5Label: String {
        String(localized: "openChat.modelOption.gpt5", defaultValue: "GPT-5")
    }

    private var gpt41Label: String {
        String(localized: "openChat.modelOption.gpt41", defaultValue: "GPT-4.1")
    }

    private var sonnetLabel: String {
        String(localized: "openChat.modelOption.sonnet", defaultValue: "Sonnet")
    }

    private var opusLabel: String {
        String(localized: "openChat.modelOption.opus", defaultValue: "Opus")
    }

    private var claudeSonnet45Label: String {
        String(localized: "openChat.modelOption.claudeSonnet45", defaultValue: "Claude Sonnet 4.5")
    }

    private var claudeOpus41Label: String {
        String(localized: "openChat.modelOption.claudeOpus41", defaultValue: "Claude Opus 4.1")
    }

    private var anthropicClaudeSonnet45Label: String {
        String(localized: "openChat.modelOption.anthropicClaudeSonnet45", defaultValue: "Anthropic Claude Sonnet 4.5")
    }

    private var anthropicClaudeOpus41Label: String {
        String(localized: "openChat.modelOption.anthropicClaudeOpus41", defaultValue: "Anthropic Claude Opus 4.1")
    }

    private var openAIGPT55Label: String {
        String(localized: "openChat.modelOption.openAIGPT55", defaultValue: "OpenAI GPT-5.5")
    }

    private var openAIGPT51Label: String {
        String(localized: "openChat.modelOption.openAIGPT51", defaultValue: "OpenAI GPT-5.1")
    }

    private var openAIGPT41Label: String {
        String(localized: "openChat.modelOption.openAIGPT41", defaultValue: "OpenAI GPT-4.1")
    }

    private var googleGemini25ProLabel: String {
        String(localized: "openChat.modelOption.googleGemini25Pro", defaultValue: "Google Gemini 2.5 Pro")
    }

    private var googleGemini25FlashLabel: String {
        String(localized: "openChat.modelOption.googleGemini25Flash", defaultValue: "Google Gemini 2.5 Flash")
    }

    private var xAIGrok4Label: String {
        String(localized: "openChat.modelOption.xAIGrok4", defaultValue: "xAI Grok 4")
    }

    private var labelFormat: String {
        String(localized: "openChat.modelOption.labelFormat", defaultValue: "%@ - %@")
    }

    private func directDefaultOption(provider: String, brand: String) -> OpenChatModelOption {
        OpenChatModelOption(
            id: "\(provider):default",
            label: combinedLabel(brand, defaultModelLabel),
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
            label: combinedLabel(brand, label),
            backendProviderID: provider,
            modelID: modelID,
            isSelected: selected
        )
    }

    private func openCodeOption(provider: String, modelID: String, label: String) -> OpenChatModelOption {
        OpenChatModelOption(
            id: "opencode:\(provider)/\(modelID)",
            label: combinedLabel(openCodeBrand, label),
            backendProviderID: "opencode",
            modelID: modelID,
            openCodeProviderID: provider,
            isSelected: false
        )
    }

    private func combinedLabel(_ brand: String, _ model: String) -> String {
        String(format: labelFormat, locale: Locale.current, brand, model)
    }
}
