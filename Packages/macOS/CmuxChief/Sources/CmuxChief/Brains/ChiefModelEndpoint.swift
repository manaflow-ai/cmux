public import Foundation

/// An Anthropic-compatible endpoint Claude Code talks to instead of Anthropic: a
/// provider that serves other models over the Messages API.
///
/// Everything reaches Claude Code through `--settings` (``settingsJSON(model:)``),
/// because flag settings outrank the project settings a Chief reads from its working
/// directory (`~/.claude/settings.json` when that is the home folder), whose `env`
/// would otherwise replace the base URL and send their credentials along. The JSON
/// holds no secret: the key comes from an `apiKeyHelper` that reads ``keyFile`` (else
/// ``keyEnvironmentKey``), so it is never in an argument list or in the environment
/// the model's tools inherit. Every model slot points at a model the endpoint
/// serves (Claude Code's background calls use the Haiku slot), and the app's own
/// Anthropic routing and credentials are blanked (``isClearedKey(_:)``).
///
/// ```swift
/// let endpoint = ChiefModelEndpoint.deepInfra(keyFile: secretFile)
/// let brain = ClaudeCodeBrain(configuration: .init(model: "moonshotai/Kimi-K3", endpoint: endpoint))
/// ```
public struct ChiefModelEndpoint: Sendable, Equatable {
    /// The provider's name in failures ("DeepInfra").
    public let name: String
    /// The base URL Claude Code appends `/v1/messages` to.
    public let baseURL: URL
    /// The model for Claude Code's background calls (its Haiku slot).
    public let smallModel: String
    /// A private file holding the key (the saved setting); nil when none is configured.
    public let keyFile: URL?
    /// The environment variable holding the key when ``keyFile`` is absent or empty.
    public let keyEnvironmentKey: String

    /// Creates an endpoint.
    ///
    /// - Parameters:
    ///   - name: The provider's name in failures.
    ///   - baseURL: The Anthropic-compatible base URL.
    ///   - smallModel: The model for background calls.
    ///   - keyFile: The file holding the saved key.
    ///   - keyEnvironmentKey: The environment variable used without a saved key.
    public init(name: String, baseURL: URL, smallModel: String, keyFile: URL?, keyEnvironmentKey: String) {
        self.name = name
        self.baseURL = baseURL
        self.smallModel = smallModel
        self.keyFile = keyFile
        self.keyEnvironmentKey = keyEnvironmentKey
    }

    /// DeepInfra's Anthropic-compatible API (`https://api.deepinfra.com/anthropic`).
    ///
    /// - Parameters:
    ///   - keyFile: The file holding the saved DeepInfra key.
    ///   - environmentKey: The variable used without a saved key.
    public static func deepInfra(keyFile: URL?, environmentKey: String = "DEEPINFRA_API_KEY") -> ChiefModelEndpoint {
        ChiefModelEndpoint(name: "DeepInfra", baseURL: URL(string: "https://api.deepinfra.com/anthropic")!,
                           smallModel: "deepseek-ai/DeepSeek-V4-Flash-0731", keyFile: keyFile,
                           keyEnvironmentKey: environmentKey)
    }

    /// Variables Claude Code reads for Anthropic routing and credentials that a third-party
    /// endpoint must not see; each is also matched by the prefixes in ``isClearedKey(_:)``.
    static let clearedKeys: [String] = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS",
        "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_UNIX_SOCKET", "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_GATEWAY_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
    ]

    /// Whether `key` is Anthropic routing or a credential: every `ANTHROPIC_*`, every
    /// `CLAUDE_CODE_USE_*` provider switch, and Claude Code's token and key-descriptor variables.
    public static func isClearedKey(_ key: String) -> Bool {
        if key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_CODE_USE_") { return true }
        guard key.hasPrefix("CLAUDE_CODE_") else { return false }
        return key.hasSuffix("_TOKEN") || key.hasSuffix("_FILE_DESCRIPTOR") || key.hasSuffix("_API_KEY")
    }

    /// Whether a key is configured: a non-empty ``keyFile``, else ``keyEnvironmentKey`` in `environment`.
    ///
    /// - Parameter environment: The environment `claude` starts with.
    public func hasKey(environment: [String: String]) -> Bool {
        if let keyFile, let text = try? String(contentsOf: keyFile, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return !(environment[keyEnvironmentKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The shell command Claude Code runs for the key: the saved file, else the variable.
    var keyHelperCommand: String {
        let fallback = "printenv \(keyEnvironmentKey)"
        guard let keyFile else { return fallback }
        let quoted = "'" + keyFile.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "cat \(quoted) 2>/dev/null || \(fallback)"
    }

    /// The `--settings` JSON that points Claude Code at this endpoint with `model`.
    ///
    /// - Parameter model: The model the turn runs with.
    public func settingsJSON(model: String) -> String {
        var environment = Dictionary(uniqueKeysWithValues: Self.clearedKeys.map { ($0, "") })
        environment.merge([
            "ANTHROPIC_BASE_URL": baseURL.absoluteString,
            "ANTHROPIC_DEFAULT_FABLE_MODEL": model,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": model,
            "ANTHROPIC_DEFAULT_SONNET_MODEL": model,
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": smallModel,
            "CLAUDE_CODE_SUBAGENT_MODEL": model,
        ]) { _, new in new }
        let settings: [String: Any] = ["env": environment, "apiKeyHelper": keyHelperCommand]
        let data = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// A failed turn's message for the user: a rejected key or an unknown model points
    /// at Chief Settings and names this provider; any other message is kept.
    ///
    /// - Parameters:
    ///   - message: Claude Code's failure text.
    ///   - model: The model id the turn ran with.
    public func failureMessage(_ message: String, model: String) -> String {
        if Self.isRejectedCredential(message) { return ChiefText.invalidCredential(name) }
        if ChiefHarness.isUnknownModelFailure(message, model: model) { return ChiefText.unknownModel(model, harness: name) }
        return message
    }

    /// Whether `message` says the endpoint rejected the key: Claude Code's "Invalid API key"
    /// and the API's 401 `authentication_error`.
    static func isRejectedCredential(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["invalid api key", "authentication_error", "invalid x-api-key"].contains(where: text.contains)
    }
}
