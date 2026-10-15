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
/// trimmed to current releases. Defaults: Claude Opus 5.5 and GPT-6.1 Sol.
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

    /// The effort levels offered for `model` of this harness; every level
    /// for an unlisted model.
    public func efforts(for model: String) -> [ChiefEffortOption] {
        self.model(model)?.efforts ?? Self.allEfforts
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
    ///   - executableOverride: An explicit CLI path; nil looks it up on `PATH`.
    /// - Returns: A brain that starts its processes lazily.
    public func makeBrain(model: String?, effort: String?, executableOverride: URL? = nil) -> any ChiefBrain {
        let model = model.flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        let effort = effort.flatMap { $0.isEmpty || $0 == "default" ? nil : $0 }
        switch self {
        case .claude:
            return ClaudeCodeBrain(configuration: .init(model: model, effort: effort, executableOverride: executableOverride))
        case .codex:
            return CodexAppServerBrain(configuration: .init(model: model, effort: effort, executableOverride: executableOverride))
        }
    }
}
