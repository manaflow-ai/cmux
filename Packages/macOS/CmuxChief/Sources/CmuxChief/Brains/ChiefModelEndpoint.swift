public import Foundation

/// An Anthropic-compatible endpoint Claude Code talks to instead of Anthropic: a
/// provider that serves other models over the Messages API.
///
/// Claude Code reads the endpoint from its environment (`ANTHROPIC_BASE_URL`,
/// `ANTHROPIC_AUTH_TOKEN`). Its background calls (titles, summaries) use the
/// Haiku slot and its subagents use their own slot, so every slot is pointed at
/// a model the endpoint serves. The app's own Anthropic credentials and provider
/// switches (``clearedKeys``) are removed so they never reach a third party.
///
/// ```swift
/// let endpoint = ChiefModelEndpoint.deepInfra(token: key)
/// let brain = ClaudeCodeBrain(configuration: .init(model: "moonshotai/Kimi-K3", endpoint: endpoint))
/// ```
public struct ChiefModelEndpoint: Sendable, Equatable {
    /// The provider's name in failures ("DeepInfra").
    public let name: String
    /// The base URL Claude Code appends `/v1/messages` to.
    public let baseURL: URL
    /// The provider API key; nil or empty fails the turn with a pointer to Chief Settings.
    public let token: String?
    /// The model for Claude Code's background calls (its Haiku slot).
    public let smallModel: String

    /// Creates an endpoint.
    ///
    /// - Parameters:
    ///   - name: The provider's name in failures.
    ///   - baseURL: The Anthropic-compatible base URL.
    ///   - token: The provider API key, nil when none is configured.
    ///   - smallModel: The model for background calls.
    public init(name: String, baseURL: URL, token: String?, smallModel: String) {
        self.name = name
        self.baseURL = baseURL
        self.token = token
        self.smallModel = smallModel
    }

    /// DeepInfra's Anthropic-compatible API (`https://api.deepinfra.com/anthropic`).
    ///
    /// - Parameter token: The user's DeepInfra API key.
    public static func deepInfra(token: String?) -> ChiefModelEndpoint {
        ChiefModelEndpoint(name: "DeepInfra", baseURL: URL(string: "https://api.deepinfra.com/anthropic")!,
                           token: token, smallModel: "deepseek-ai/DeepSeek-V4-Flash-0731")
    }

    /// Environment keys removed before Claude Code starts: Anthropic credentials,
    /// custom headers and cloud-provider switches the app may have been launched with.
    public static let clearedKeys: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_CUSTOM_HEADERS",
        "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
    ]

    /// The variables that point Claude Code at this endpoint with `model`.
    ///
    /// - Parameter model: The model the turn runs with.
    public func environment(model: String) -> [String: String] {
        var environment = [
            "ANTHROPIC_BASE_URL": baseURL.absoluteString,
            "ANTHROPIC_DEFAULT_FABLE_MODEL": model,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": model,
            "ANTHROPIC_DEFAULT_SONNET_MODEL": model,
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": smallModel,
            "CLAUDE_CODE_SUBAGENT_MODEL": model,
        ]
        if let token, !token.isEmpty { environment["ANTHROPIC_AUTH_TOKEN"] = token }
        return environment
    }

    /// Whether a key is configured.
    var hasToken: Bool { !(token ?? "").isEmpty }

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

extension ChiefModelEndpoint: CustomStringConvertible, CustomDebugStringConvertible {
    /// The endpoint without its token, safe for logs.
    public var description: String {
        "ChiefModelEndpoint(\(name), \(baseURL.absoluteString), token: \(hasToken ? "set" : "none"))"
    }

    public var debugDescription: String { description }
}
