public import Foundation

/// A model provider the Accounts screen knows about. The raw value is the
/// stable id used in the CLI (`cmux accounts reauth --provider codex`), the
/// control socket and the cmux Keychain account name.
public enum AIProvider: String, CaseIterable, Sendable, Codable, Hashable {
    case codex
    case openAI = "openai"
    case claude
    case anthropic
    case gemini
    case openRouter = "openrouter"
    case groq
    case xai
    case mistral
    case deepseek
    case bedrock
    case vertex
    case copilot
    case ollama
    case lmStudio = "lmstudio"
    /// OpenCode Go: CodeRouter can hold its account; cmux detects nothing locally.
    case openCodeGo = "opencode-go"

    /// How the screen groups providers.
    public enum Group: String, Sendable, CaseIterable {
        case chatGPT, anthropic, other, local
    }

    public var group: Group {
        switch self {
        case .codex, .openAI: .chatGPT
        case .claude, .anthropic: .anthropic
        case .ollama, .lmStudio: .local
        default: .other
        }
    }

    /// Product names (never localized).
    public var displayName: String {
        switch self {
        case .codex: "ChatGPT / Codex"
        case .openAI: "OpenAI API"
        case .claude: "Claude Code"
        case .anthropic: "Anthropic API"
        case .gemini: "Gemini"
        case .openRouter: "OpenRouter"
        case .groq: "Groq"
        case .xai: "xAI"
        case .mistral: "Mistral"
        case .deepseek: "DeepSeek"
        case .bedrock: "Amazon Bedrock"
        case .vertex: "Google Vertex AI"
        case .copilot: "GitHub Copilot"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .openCodeGo: "OpenCode Go"
        }
    }

    /// The environment variables that hold this provider's API key, in the
    /// order a tool reads them. Only presence is ever checked.
    public var apiKeyEnvironmentKeys: [String] {
        switch self {
        case .openAI: ["OPENAI_API_KEY"]
        case .anthropic: ["ANTHROPIC_API_KEY"]
        case .gemini: ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        case .openRouter: ["OPENROUTER_API_KEY"]
        case .groq: ["GROQ_API_KEY"]
        case .xai: ["XAI_API_KEY"]
        case .mistral: ["MISTRAL_API_KEY"]
        case .deepseek: ["DEEPSEEK_API_KEY"]
        default: []
        }
    }

    /// The provider authenticates with one pasted API key, which cmux can
    /// keep in the Keychain.
    public var acceptsPastedKey: Bool { !apiKeyEnvironmentKeys.isEmpty }

    /// A local model server: "running" instead of "signed in".
    public var isLocalServer: Bool { self == .ollama || self == .lmStudio }

    /// Where the user gets a new API key (opened in a cmux browser tab).
    public var consoleURL: URL? {
        let raw: String? = switch self {
        case .openAI: "https://platform.openai.com/api-keys"
        case .anthropic: "https://console.anthropic.com/settings/keys"
        case .gemini: "https://aistudio.google.com/app/apikey"
        case .openRouter: "https://openrouter.ai/settings/keys"
        case .groq: "https://console.groq.com/keys"
        case .xai: "https://console.x.ai"
        case .mistral: "https://console.mistral.ai/api-keys"
        case .deepseek: "https://platform.deepseek.com/api_keys"
        case .copilot: "https://github.com/settings/copilot"
        case .ollama: "https://ollama.com/download"
        case .lmStudio: "https://lmstudio.ai"
        case .bedrock: "https://console.aws.amazon.com/bedrock"
        case .vertex: "https://console.cloud.google.com/vertex-ai"
        case .codex, .claude, .openCodeGo: nil
        }
        return raw.flatMap(URL.init(string:))
    }
}
