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
/// let models = ChiefModelCatalog.models(for: .claude)
/// let model = ChiefModelCatalog.defaultModel(for: .codex) // "gpt-6.1-sol"
/// ```
public enum ChiefModelCatalog {
    private static let allEfforts: [ChiefEffortOption] = [.low, .medium, .high, .xhigh, .max]

    /// Claude Code models, default first.
    public static let claudeModels: [ChiefModelOption] = [
        ChiefModelOption(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", efforts: allEfforts),
        ChiefModelOption(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5", efforts: allEfforts),
        ChiefModelOption(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5", efforts: allEfforts),
        ChiefModelOption(id: "claude-fable-5-1", displayName: "Claude Fable 5.1", efforts: allEfforts),
    ]

    /// Codex models, default first.
    public static let codexModels: [ChiefModelOption] = [
        ChiefModelOption(id: "gpt-6.1-sol", displayName: "GPT-6.1 Sol", efforts: allEfforts),
        ChiefModelOption(id: "gpt-6-sol", displayName: "GPT-6 Sol", efforts: allEfforts),
        ChiefModelOption(id: "gpt-6-astra", displayName: "GPT-6 Astra", efforts: allEfforts),
        ChiefModelOption(id: "gpt-6-luna", displayName: "GPT-6 Luna", efforts: allEfforts),
        ChiefModelOption(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", efforts: allEfforts),
        ChiefModelOption(id: "gpt-5.5", displayName: "GPT-5.5", efforts: [.low, .medium, .high, .xhigh]),
    ]

    /// The models offered for `harness`, default first.
    public static func models(for harness: ChiefHarness) -> [ChiefModelOption] {
        switch harness {
        case .claude: return claudeModels
        case .codex: return codexModels
        }
    }

    /// The default model id for `harness`.
    public static func defaultModel(for harness: ChiefHarness) -> String {
        models(for: harness)[0].id
    }

    /// The model `id` of `harness`, nil for an id the catalog does not list
    /// (a custom id still runs; the CLI decides).
    public static func model(_ id: String, for harness: ChiefHarness) -> ChiefModelOption? {
        models(for: harness).first { $0.id == id }
    }

    /// The effort levels offered for `model` of `harness`; every level for an
    /// unlisted model.
    public static func efforts(for model: String, harness: ChiefHarness) -> [ChiefEffortOption] {
        self.model(model, for: harness)?.efforts ?? allEfforts
    }
}

/// Builds the ``ChiefBrain`` for a harness, model and effort.
///
/// ```swift
/// let brain = ChiefBrainFactory.make(harness: "claude", model: nil, effort: "high")
/// ```
public enum ChiefBrainFactory {
    /// A brain for `harness`.
    ///
    /// - Parameters:
    ///   - harness: The harness; an unknown value falls back to Claude Code.
    ///   - model: The model id; nil or empty uses the harness default.
    ///   - effort: The effort level; nil or empty uses the model default.
    ///   - executableOverride: An explicit CLI path; nil looks it up on `PATH`.
    /// - Returns: A brain that starts its processes lazily.
    public static func make(harness: ChiefHarness, model: String?, effort: String?,
                            executableOverride: URL? = nil) -> any ChiefBrain {
        let model = model.flatMap { $0.isEmpty ? nil : $0 } ?? ChiefModelCatalog.defaultModel(for: harness)
        let effort = effort.flatMap { $0.isEmpty || $0 == "default" ? nil : $0 }
        switch harness {
        case .claude:
            return ClaudeCodeBrain(configuration: .init(model: model, effort: effort, executableOverride: executableOverride))
        case .codex:
            return CodexAppServerBrain(configuration: .init(model: model, effort: effort, executableOverride: executableOverride))
        }
    }

    /// A brain for a harness name (`"claude"` or `"codex"`).
    public static func make(harness: String, model: String?, effort: String?,
                            executableOverride: URL? = nil) -> any ChiefBrain {
        make(harness: ChiefHarness(rawValue: harness.lowercased()) ?? .claude, model: model, effort: effort,
             executableOverride: executableOverride)
    }
}
