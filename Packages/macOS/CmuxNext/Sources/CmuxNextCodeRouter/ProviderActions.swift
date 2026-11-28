public import Foundation

/// How a provider signs in again. cmux never implements a provider's own
/// login: it runs the provider's CLI in a visible cmux terminal (so the
/// user sees and answers it), or opens the provider's page in a cmux
/// browser tab.
public enum ReauthPlan: Sendable, Equatable {
    /// Run this argv in a new terminal tab. Arguments are fixed strings,
    /// never user input.
    case command([String])
    /// Open this page in a browser tab.
    case page(URL)
    /// Nothing to sign in to (a local server, a link-only provider).
    case none

    /// The shell text typed into the terminal tab for `.command`.
    public var shellLine: String? {
        guard case .command(let argv) = self else { return nil }
        return argv.map(Self.quoted).joined(separator: " ")
    }

    static func quoted(_ word: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@"))
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// What CodeRouter can hold for a provider (web/services/coderouter/types.ts
/// and claudeUpstream.ts). Everything else cannot be linked yet.
public enum CodeRouterLinkKind: Sendable, Equatable {
    /// The Codex CLI's ChatGPT sign-in (`POST /api/coderouter/accounts`, provider `codex`).
    case codexOAuth
    /// One API key (`POST /api/coderouter/accounts`, `openai-apikey` / `openrouter-apikey`).
    case apiKey(serverProvider: String)
    /// A Claude Code OAuth token from `claude setup-token` (`POST /api/coderouter/claude-upstream`).
    case claudeOAuthToken
    /// An Anthropic API key (`POST /api/coderouter/claude-upstream`, `anthropic_api_key`).
    case anthropicAPIKey
    /// AWS access keys from the environment (`claude-upstream`, `bedrock`).
    case bedrockKeys
    /// CodeRouter does not route this provider.
    case unsupported
}

extension AIProvider {
    public var reauthPlan: ReauthPlan {
        switch self {
        case .codex: .command(["codex", "login"])
        // `claude auth login` (Claude Code's `auth` command, per `claude auth --help`).
        case .claude: .command(["claude", "auth", "login"])
        case .gemini: .command(["gemini"])
        case .bedrock: .command(["aws", "sso", "login"])
        case .vertex: .command(["gcloud", "auth", "application-default", "login"])
        case .copilot: .command(["gh", "auth", "login", "--web"])
        case .openAI, .anthropic, .openRouter, .groq, .xai, .mistral, .deepseek:
            consoleURL.map(ReauthPlan.page) ?? .none
        case .ollama, .lmStudio, .openCodeGo: .none
        }
    }

    public var codeRouterLink: CodeRouterLinkKind {
        switch self {
        case .codex: .codexOAuth
        case .openAI: .apiKey(serverProvider: "openai-apikey")
        case .openRouter: .apiKey(serverProvider: "openrouter-apikey")
        case .claude: .claudeOAuthToken
        case .anthropic: .anthropicAPIKey
        case .bedrock: .bedrockKeys
        default: .unsupported
        }
    }

    /// CodeRouter's provider name for an account row, mapped back.
    public static func fromCodeRouter(provider: String) -> AIProvider? {
        switch provider {
        case "codex": .codex
        case "openai-apikey": .openAI
        case "openrouter-apikey": .openRouter
        case "opencode-go": .openCodeGo
        default: nil
        }
    }

    /// A Claude upstream account kind, mapped back.
    public static func fromClaudeUpstream(kind: String) -> AIProvider? {
        switch kind {
        case "anthropic_oauth": .claude
        case "anthropic_api_key": .anthropic
        case "bedrock": .bedrock
        default: nil
        }
    }
}
