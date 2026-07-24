import Foundation

/// Known coding-agent CLIs the composer can offer model choices for.
public enum MobileTaskAgentProvider: String, CaseIterable, Sendable {
    /// Anthropic's Claude Code CLI.
    case claude
    /// OpenAI's Codex CLI.
    case codex
    /// The OpenCode CLI.
    case openCode
}

/// One selectable model for a coding-agent provider.
public struct MobileTaskAgentModel: Equatable, Sendable, Identifiable {
    /// CLI identifier passed to the provider's model flag.
    public let id: String
    /// Product name displayed verbatim in the composer.
    public let displayName: String

    /// Creates a selectable coding-agent model.
    /// - Parameters:
    ///   - id: CLI identifier passed to the provider's model flag.
    ///   - displayName: Product name displayed verbatim in the composer.
    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// Curated per-provider model lists and the CLI flag spelling used to apply one.
/// lint:allow namespace-type — the task spec requires this static catalog API.
public enum MobileTaskAgentModelCatalog {
    /// Lexically detects a provider from the command's first
    /// whitespace-delimited token.
    ///
    /// Detection ignores the token's path, but does not parse shell syntax, so
    /// compound or environment-prefixed commands return `nil`.
    /// - Parameter command: User-authored task-template command.
    /// - Returns: The detected provider, or `nil` for an unsupported first token.
    public static func provider(forCommand command: String) -> MobileTaskAgentProvider? {
        guard let tokenRange = firstTokenRange(in: command) else { return nil }
        let token = command[tokenRange]
        let basename = token.split(separator: "/", omittingEmptySubsequences: true).last
        switch basename {
        case "claude":
            return .claude
        case "codex":
            return .codex
        case "opencode":
            return .openCode
        default:
            return nil
        }
    }

    /// Returns the curated models available for a provider.
    /// - Parameter provider: Coding-agent provider to look up.
    /// - Returns: Models offered by that provider, in display order.
    public static func models(for provider: MobileTaskAgentProvider) -> [MobileTaskAgentModel] {
        switch provider {
        case .claude:
            [
                MobileTaskAgentModel(id: "claude-fable-5", displayName: "Fable 5"),
                MobileTaskAgentModel(id: "claude-opus-4-8", displayName: "Opus 4.8"),
                MobileTaskAgentModel(id: "claude-sonnet-5", displayName: "Sonnet 5"),
                MobileTaskAgentModel(id: "claude-haiku-4-5", displayName: "Haiku 4.5"),
            ]
        case .codex:
            [
                MobileTaskAgentModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol"),
                MobileTaskAgentModel(id: "gpt-5.5", displayName: "GPT-5.5"),
            ]
        case .openCode:
            [
                MobileTaskAgentModel(
                    id: "anthropic/claude-sonnet-5",
                    displayName: "Claude Sonnet 5"
                ),
                MobileTaskAgentModel(
                    id: "anthropic/claude-opus-4-8",
                    displayName: "Claude Opus 4.8"
                ),
                MobileTaskAgentModel(id: "openai/gpt-5.5", displayName: "GPT-5.5"),
            ]
        }
    }

    /// Returns the curated models for a command's detected provider.
    /// - Parameter command: User-authored task-template command.
    /// - Returns: Available models, or an empty array for an unsupported command.
    public static func models(forCommand command: String) -> [MobileTaskAgentModel] {
        guard let provider = provider(forCommand: command) else { return [] }
        return models(for: provider)
    }

    /// Validates a model identifier against a command's detected provider.
    /// - Parameters:
    ///   - id: CLI model identifier to validate.
    ///   - command: User-authored task-template command.
    /// - Returns: The matching curated model, or `nil` when it is unavailable.
    public static func model(id: String, forCommand command: String) -> MobileTaskAgentModel? {
        models(forCommand: command).first { $0.id == id }
    }

    /// Inserts a provider-specific model flag immediately after the command's
    /// first token.
    ///
    /// A `nil` model identifier or unsupported command is returned unchanged.
    /// Everything after the first token remains byte-for-byte identical.
    /// - Parameters:
    ///   - modelID: CLI model identifier to single-quote for the flag value.
    ///   - command: User-authored task-template command.
    /// - Returns: The flagged command, or the original command when not applicable.
    public static func commandApplying(modelID: String?, to command: String) -> String {
        guard let modelID,
              let provider = provider(forCommand: command),
              let tokenRange = firstTokenRange(in: command) else {
            return command
        }
        let flag = switch provider {
        case .claude, .openCode:
            "--model"
        case .codex:
            "-m"
        }
        let escapedID = modelID.replacingOccurrences(of: "'", with: "'\\''")
        return "\(command[..<tokenRange.upperBound]) \(flag) '\(escapedID)'\(command[tokenRange.upperBound...])"
    }

    private static func firstTokenRange(in command: String) -> Range<String.Index>? {
        guard let start = command.firstIndex(where: { !$0.isWhitespace }) else { return nil }
        let end = command[start...].firstIndex(where: \.isWhitespace) ?? command.endIndex
        return start..<end
    }
}
