public import Foundation

/// The agent CLI a Chief runs on.
public enum ChiefHarness: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Claude Code (`claude -p` stream-json).
    case claude
    /// Codex (`codex app-server`).
    case codex

    public var id: String { rawValue }

    /// The name shown in pickers.
    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

/// One model a picker offers.
public struct ChiefModelOption: Sendable, Equatable, Identifiable, Hashable {
    /// The id passed to the CLI.
    public let id: String
    /// The name shown in pickers.
    public let displayName: String
    /// The effort levels the model takes, lowest first.
    public let efforts: [ChiefEffortOption]

    /// Creates an option.
    public init(id: String, displayName: String, efforts: [ChiefEffortOption]) {
        self.id = id
        self.displayName = displayName
        self.efforts = efforts
    }
}

/// One effort (reasoning) level a picker offers.
public struct ChiefEffortOption: Sendable, Equatable, Identifiable, Hashable {
    /// The value passed to the CLI (`--effort`, `turn/start` `effort`).
    public let id: String
    /// The name shown in pickers.
    public let displayName: String

    /// Creates an option.
    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    public static let low = ChiefEffortOption(id: "low", displayName: "Low")
    public static let medium = ChiefEffortOption(id: "medium", displayName: "Medium")
    public static let high = ChiefEffortOption(id: "high", displayName: "High")
    public static let xhigh = ChiefEffortOption(id: "xhigh", displayName: "Extra High")
    public static let max = ChiefEffortOption(id: "max", displayName: "Max")
}

/// The models and effort levels the Chief's picker offers per harness.
///
/// The ids and effort sets follow acpmux's bundled catalog
/// (`cmux-tui/crates/acpmux/catalog/models-v1.json` on `feat-cmux-next`),
/// trimmed to current releases. Defaults: Claude Opus 5.5 and GPT-6.1 Sol. Each model offers
/// exactly the `efforts` its catalog row lists (snapshot 2026-10-13: every Claude 5.x model,
/// Haiku 5.5 and Fable 5.1 included, takes all five `--effort` levels `claude --help` names;
/// GPT-5.5 stops at Extra High). `ChiefModelCatalogTests` pins the rows; update both when
/// acpmux's catalog changes.
///
/// ```swift
/// let models = ChiefHarness.claude.models
/// let model = ChiefHarness.codex.defaultModel // "gpt-6.1-sol"
/// ```
extension ChiefHarness {
    private static let allEfforts: [ChiefEffortOption] = [.low, .medium, .high, .xhigh, .max]

    /// Claude Code models, default first.
    private static let claudeModels: [ChiefModelOption] = [
        ChiefModelOption(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", efforts: allEfforts),
        ChiefModelOption(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5", efforts: allEfforts),
        ChiefModelOption(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5", efforts: allEfforts),
        ChiefModelOption(id: "claude-fable-5-1", displayName: "Claude Fable 5.1", efforts: allEfforts),
    ]

    /// Codex models, default first.
    private static let codexModels: [ChiefModelOption] = [
        ChiefModelOption(id: "gpt-6.1-sol", displayName: "GPT-6.1 Sol", efforts: allEfforts),
        ChiefModelOption(id: "gpt-6-sol", displayName: "GPT-6 Sol", efforts: allEfforts),
        ChiefModelOption(id: "gpt-6-astra", displayName: "GPT-6 Astra", efforts: allEfforts),
        ChiefModelOption(id: "gpt-6-luna", displayName: "GPT-6 Luna", efforts: allEfforts),
        ChiefModelOption(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", efforts: allEfforts),
        ChiefModelOption(id: "gpt-5.5", displayName: "GPT-5.5", efforts: [.low, .medium, .high, .xhigh]),
    ]

    /// The harness a settings value names (`"claude"` or `"codex"`, any
    /// case); an unknown value falls back to Claude Code.
    public init(lenient name: String) {
        self = ChiefHarness(rawValue: name.lowercased()) ?? .claude
    }

    /// The models offered for this harness, default first.
    public var models: [ChiefModelOption] {
        switch self {
        case .claude: return Self.claudeModels
        case .codex: return Self.codexModels
        }
    }

    /// The default model id for this harness.
    public var defaultModel: String {
        models[0].id
    }

    /// The model `id` of this harness, nil for an id the catalog does not
    /// list (a custom id still runs; the CLI decides).
    public func model(_ id: String) -> ChiefModelOption? {
        models.first { $0.id == id }
    }

    /// A failed turn's message for the user: a failure that says the CLI does not know or
    /// offer `model` (a typo, a retired id, a plan without it) becomes one that names the
    /// model and points at Chief Settings; any other message is kept.
    ///
    /// - Parameters:
    ///   - message: The CLI's failure text.
    ///   - model: The model id the turn ran with.
    public func failureMessage(_ message: String, model: String) -> String {
        Self.isUnknownModelFailure(message, model: model) ? ChiefText.unknownModel(model, harness: displayName) : message
    }

    /// Whether `message` says the CLI rejected `model`: Claude Code's "issue with the selected
    /// model" and `unrecognized_model`, the API's `not_found_error` "model: <id>", Codex's
    /// "model … does not exist", "is not supported" and `model_not_found`.
    static func isUnknownModelFailure(_ message: String, model: String) -> Bool {
        let text = message.lowercased()
        let generic = ["issue with the selected model", "unrecognized_model", "model_not_found", "unknown model",
                       "invalid model", "model not found", "model is not supported", "model is not available"]
        if generic.contains(where: text.contains) { return true }
        let id = model.lowercased()
        guard !id.isEmpty, text.contains(id) else { return false }
        return ["model: \(id)", "does not exist", "not supported", "not_found_error", "not found", "do not have access"]
            .contains(where: text.contains)
    }

    /// The effort levels offered for `model` of this harness.
    ///
    /// An unlisted model is still accepted by the harness (the CLI may know a
    /// model newer than this app), but its capabilities are unknown. Returning
    /// no explicit levels keeps the settings picker on the model's own default
    /// instead of offering flags that could be rejected by that CLI.
    public func efforts(for model: String) -> [ChiefEffortOption] {
        self.model(model)?.efforts ?? []
    }

    /// Builds the ``ChiefBrain`` for this harness, a model and an effort.
    ///
    /// ```swift
    /// let brain = ChiefHarness(lenient: "claude").makeBrain(model: nil, effort: "high")
    /// ```
    ///
    /// - Parameters:
    ///   - model: The model id; nil or empty uses the harness default.
    ///   - effort: The effort level; nil or empty uses the model default.
    ///   - dangerouslySkipPermissions: Whether the harness may bypass permission prompts.
    ///   - executableOverride: An explicit CLI path; nil looks it up on `PATH`.
    /// - Returns: A brain that starts its processes lazily.
    public func makeBrain(
        model: String?,
        effort: String?,
        dangerouslySkipPermissions: Bool = false,
        executableOverride: URL? = nil,
        allowRules: ChiefAllowRules? = nil
    ) -> any ChiefBrain {
        let model = model.flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        let effort = effort.flatMap { $0.isEmpty || $0 == "default" ? nil : $0 }
        switch self {
        case .claude:
            return ClaudeCodeBrain(configuration: .init(model: model, effort: effort,
                                                        dangerouslySkipPermissions: dangerouslySkipPermissions,
                                                        executableOverride: executableOverride),
                                    allowRules: allowRules)
        case .codex:
            return CodexAppServerBrain(configuration: .init(model: model, effort: effort,
                                                            dangerouslySkipPermissions: dangerouslySkipPermissions,
                                                            executableOverride: executableOverride),
                                    allowRules: allowRules)
        }
    }
}
