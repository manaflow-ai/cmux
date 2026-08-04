import CmuxControlSocket
import Foundation

enum AIAccountProvider: String, Sendable {
    case claude
    case codex
    case anthropicKey = "anthropic-key"
    case openAIKey = "openai-key"

    var apiProvider: String {
        switch self {
        case .claude:
            return "claude"
        case .codex:
            return "codex"
        case .anthropicKey:
            return "anthropic-apikey"
        case .openAIKey:
            return "openai-apikey"
        }
    }

    var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .anthropicKey:
            return "Anthropic API key"
        case .openAIKey:
            return "OpenAI API key"
        }
    }

    var environmentKeyName: String? {
        switch self {
        case .anthropicKey:
            return "ANTHROPIC_API_KEY"
        case .openAIKey:
            return "OPENAI_API_KEY"
        case .claude, .codex:
            return nil
        }
    }
}

enum AIAccountCredentialSourceError: Error, CustomStringConvertible {
    case unsupportedProvider(String)
    case invalidJSON(source: String)
    case missingClaudeOAuth
    case missingClaudeOAuthField(String)
    case missingCodexTokens(openAIAPIKeyPresent: Bool)
    case missingCodexTokenField(String)
    case missingAPIKey(provider: AIAccountProvider)
    case unreadableCredentials(provider: AIAccountProvider, path: String)

    var description: String {
        switch self {
        case let .unsupportedProvider(value):
            return "Unsupported AI account provider '\(value)'. Use claude, codex, anthropic-key, or openai-key."
        case let .invalidJSON(source):
            return "\(source) credentials file is not valid JSON."
        case .missingClaudeOAuth:
            return "Claude credentials were not found. Run `claude login`, then retry."
        case let .missingClaudeOAuthField(field):
            return "Claude credentials are missing required field `\(field)`. Run `claude login`, then retry."
        case let .missingCodexTokens(openAIAPIKeyPresent):
            if openAIAPIKeyPresent {
                return "Codex auth contains an OpenAI API key but no OAuth tokens. Use `cmux ai-accounts upload openai-key` instead."
            }
            return "Codex OAuth tokens were not found. Run `codex login`, then retry."
        case let .missingCodexTokenField(field):
            return "Codex OAuth tokens are missing required field `\(field)`. Run `codex login`, then retry."
        case let .missingAPIKey(provider):
            let envName = provider.environmentKeyName ?? "API_KEY"
            return "\(provider.displayName) upload requires `--key <value>` or \(envName) in the cmux app environment."
        case let .unreadableCredentials(provider, path):
            return "Could not read \(provider.displayName) credentials at \(path). Sign in locally, then retry."
        }
    }
}

struct AIAccountUploadPayload: Sendable, CustomDebugStringConvertible {
    let provider: AIAccountProvider
    let label: String?
    private let credential: Credential

    /// Credential values are stored as typed `JSONValue` trees (not
    /// `[String: Any]`) so the payload is `Sendable` and can cross into the
    /// `AIAccountsClient` actor without carrying untyped JSONSerialization
    /// output across isolation boundaries.
    enum Credential: Sendable {
        case claudeOAuth([String: JSONValue])
        case codexTokens([String: JSONValue])
        case apiKey(String)
    }

    init(provider: AIAccountProvider, label: String?, credential: Credential) {
        self.provider = provider
        self.label = label
        self.credential = credential
    }

    /// Foundation-shaped body for `JSONSerialization`; only used at the HTTP
    /// boundary inside `AIAccountsClient`.
    var jsonBody: [String: Any] {
        var body: [String: Any] = ["provider": provider.apiProvider]
        if let label, !label.isEmpty {
            body["label"] = label
        }
        switch credential {
        case let .claudeOAuth(value):
            body["claudeAiOauth"] = value.mapValues(\.foundationObject)
        case let .codexTokens(value):
            body["tokens"] = value.mapValues(\.foundationObject)
        case let .apiKey(value):
            body["apiKey"] = value
        }
        return body
    }

    var debugDescription: String {
        "AIAccountUploadPayload(provider: \(provider.rawValue), label: \(label ?? "nil"), credential: <redacted>)"
    }
}

struct AIAccountCredentialSources {
    let homeDirectory: URL
    let environment: [String: String]

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    func uploadPayload(
        provider: AIAccountProvider,
        label: String?,
        explicitAPIKey: String?
    ) throws -> AIAccountUploadPayload {
        switch provider {
        case .claude:
            let url = homeDirectory
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent(".credentials.json", isDirectory: false)
            guard let data = try? Data(contentsOf: url) else {
                throw AIAccountCredentialSourceError.unreadableCredentials(provider: provider, path: "~/.claude/.credentials.json")
            }
            return try claudeUploadPayload(credentialsData: data, label: label)
        case .codex:
            let url = homeDirectory
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("auth.json", isDirectory: false)
            guard let data = try? Data(contentsOf: url) else {
                throw AIAccountCredentialSourceError.unreadableCredentials(provider: provider, path: "~/.codex/auth.json")
            }
            return try codexUploadPayload(authData: data, label: label)
        case .anthropicKey, .openAIKey:
            return try apiKeyUploadPayload(provider: provider, label: label, explicitAPIKey: explicitAPIKey)
        }
    }

    func claudeUploadPayload(credentialsData: Data, label: String?) throws -> AIAccountUploadPayload {
        let root = try jsonObject(credentialsData, source: "Claude")
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else {
            throw AIAccountCredentialSourceError.missingClaudeOAuth
        }
        for field in ["accessToken", "refreshToken", "expiresAt"] where !Self.hasNonEmptyJSONValue(oauth[field]) {
            throw AIAccountCredentialSourceError.missingClaudeOAuthField(field)
        }

        var forwarded: [String: JSONValue] = [:]
        for field in ["accessToken", "refreshToken", "expiresAt", "subscriptionType", "rateLimitTier"] {
            if let value = oauth[field], let bridged = JSONValue(foundationObject: value) {
                forwarded[field] = bridged
            }
        }
        return AIAccountUploadPayload(provider: .claude, label: normalizedLabel(label), credential: .claudeOAuth(forwarded))
    }

    func codexUploadPayload(authData: Data, label: String?) throws -> AIAccountUploadPayload {
        let root = try jsonObject(authData, source: "Codex")
        guard let tokens = root["tokens"] as? [String: Any] else {
            throw AIAccountCredentialSourceError.missingCodexTokens(openAIAPIKeyPresent: Self.hasNonEmptyJSONValue(root["OPENAI_API_KEY"]))
        }

        let mapping = [
            ("access_token", "accessToken"),
            ("refresh_token", "refreshToken"),
            ("id_token", "idToken"),
            ("account_id", "accountID"),
        ]
        var forwarded: [String: JSONValue] = [:]
        for (source, target) in mapping {
            guard let raw = tokens[source], Self.hasNonEmptyJSONValue(raw),
                  let bridged = JSONValue(foundationObject: raw) else {
                throw AIAccountCredentialSourceError.missingCodexTokenField(source)
            }
            forwarded[target] = bridged
        }
        return AIAccountUploadPayload(provider: .codex, label: normalizedLabel(label), credential: .codexTokens(forwarded))
    }

    func apiKeyUploadPayload(
        provider: AIAccountProvider,
        label: String?,
        explicitAPIKey: String?
    ) throws -> AIAccountUploadPayload {
        guard provider == .anthropicKey || provider == .openAIKey else {
            throw AIAccountCredentialSourceError.unsupportedProvider(provider.rawValue)
        }
        let explicit = explicitAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let envValue = provider.environmentKeyName.flatMap { environment[$0] }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = [explicit, envValue].compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            throw AIAccountCredentialSourceError.missingAPIKey(provider: provider)
        }
        return AIAccountUploadPayload(provider: provider, label: normalizedLabel(label), credential: .apiKey(key))
    }

    private func jsonObject(_ data: Data, source: String) throws -> [String: Any] {
        do {
            let parsed = try JSONSerialization.jsonObject(with: data, options: [])
            guard let object = parsed as? [String: Any] else {
                throw AIAccountCredentialSourceError.invalidJSON(source: source)
            }
            return object
        } catch let error as AIAccountCredentialSourceError {
            throw error
        } catch {
            throw AIAccountCredentialSourceError.invalidJSON(source: source)
        }
    }

    private func normalizedLabel(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func hasNonEmptyJSONValue(_ value: Any?) -> Bool {
        guard let value else { return false }
        if value is NSNull { return false }
        if let string = value as? String {
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return JSONSerialization.isValidJSONObject(["value": value])
    }
}
