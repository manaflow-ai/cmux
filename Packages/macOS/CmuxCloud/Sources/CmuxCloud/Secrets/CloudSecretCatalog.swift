import Foundation

/// Well-known secret names: the quick-add presets and what "import from shell" looks for.
/// lint:allow namespace-type: the contract's static catalog; a fixed table with no state or dependencies.
public enum CloudSecretCatalog {
    /// What the provider calls the credential, so copy can say "API key" or
    /// "token" instead of one word for both.
    public enum Credential: String, Sendable, Hashable {
        case apiKey
        case token
    }

    /// One quick-add preset. `label` is the provider's brand name, not localized.
    public struct Preset: Sendable, Hashable {
        public let name: String
        public let label: String
        /// The CLIs on a machine that read this variable.
        public let agents: [String]
        /// Where to create a key.
        public let docsURL: URL?
        /// An API key or a token.
        public let credential: Credential

        public init(name: String, label: String, agents: [String], docsURL: URL?, credential: Credential = .apiKey) {
            self.name = name
            self.label = label
            self.agents = agents
            self.docsURL = docsURL
            self.credential = credential
        }
    }

    public static let presets: [Preset] = [
        Preset(name: "ANTHROPIC_API_KEY", label: "Anthropic", agents: ["claude", "opencode", "pi"], docsURL: URL(string: "https://console.anthropic.com/settings/keys")),
        Preset(name: "OPENAI_API_KEY", label: "OpenAI", agents: ["codex", "opencode", "pi"], docsURL: URL(string: "https://platform.openai.com/api-keys")),
        Preset(name: "GH_TOKEN", label: "GitHub", agents: ["gh", "git"], docsURL: URL(string: "https://github.com/settings/tokens"), credential: .token),
        Preset(name: "GEMINI_API_KEY", label: "Gemini", agents: ["gemini", "opencode", "pi"], docsURL: URL(string: "https://aistudio.google.com/apikey")),
        Preset(name: "OPENROUTER_API_KEY", label: "OpenRouter", agents: ["opencode", "pi"], docsURL: URL(string: "https://openrouter.ai/keys")),
        Preset(name: "XAI_API_KEY", label: "xAI", agents: ["opencode", "pi"], docsURL: URL(string: "https://console.x.ai")),
        Preset(name: "GROQ_API_KEY", label: "Groq", agents: ["opencode", "pi"], docsURL: URL(string: "https://console.groq.com/keys")),
        Preset(name: "MISTRAL_API_KEY", label: "Mistral", agents: ["opencode", "pi"], docsURL: URL(string: "https://console.mistral.ai/api-keys")),
        Preset(name: "DEEPSEEK_API_KEY", label: "DeepSeek", agents: ["opencode", "pi"], docsURL: URL(string: "https://platform.deepseek.com/api_keys")),
        Preset(name: "HF_TOKEN", label: "Hugging Face", agents: ["huggingface-cli"], docsURL: URL(string: "https://huggingface.co/settings/tokens"), credential: .token),
        Preset(name: "NPM_TOKEN", label: "npm", agents: ["npm"], docsURL: URL(string: "https://docs.npmjs.com/creating-and-viewing-access-tokens"), credential: .token)
    ]

    /// Names recognized besides the presets' own.
    static let additionalWellKnownNames: Set<String> = [
        "GITHUB_TOKEN", "GOOGLE_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"
    ]

    /// Every well-known name, sorted.
    public static var wellKnownNames: [String] {
        Set(presets.map(\.name)).union(additionalWellKnownNames).sorted()
    }

    public static func isWellKnown(_ name: String) -> Bool {
        presets.contains { $0.name == name } || additionalWellKnownNames.contains(name)
    }
}
