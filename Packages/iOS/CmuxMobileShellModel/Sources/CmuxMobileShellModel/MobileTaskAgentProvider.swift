import Foundation

/// Known coding-agent CLIs the composer can offer model choices for, each
/// owning its curated model list and model-flag spelling.
public enum MobileTaskAgentProvider: String, CaseIterable, Sendable {
    /// Anthropic's Claude Code CLI.
    case claude
    /// OpenAI's Codex CLI.
    case codex
    /// The OpenCode CLI.
    case openCode

    /// Lexically detects a provider from the command's first
    /// whitespace-delimited token.
    ///
    /// Detection ignores the token's path, but does not parse shell syntax, so
    /// compound or environment-prefixed commands detect no provider.
    /// - Parameter command: User-authored task-template command.
    public init?(command: String) {
        guard let tokenRange = Self.tokenRange(in: command, from: command.startIndex) else {
            return nil
        }
        let token = command[tokenRange]
        let basename = token.split(separator: "/", omittingEmptySubsequences: true).last
        switch basename {
        case "claude":
            self = .claude
        case "codex":
            self = .codex
        case "opencode":
            self = .openCode
        default:
            return nil
        }
    }

    /// The curated models offered for this provider, in display order.
    public var models: [MobileTaskAgentModel] {
        switch self {
        case .claude:
            [
                MobileTaskAgentModel(id: "claude-fable-5", displayName: "Fable 5"),
                MobileTaskAgentModel(id: "claude-opus-4-8", displayName: "Opus 4.8"),
                MobileTaskAgentModel(id: "claude-sonnet-5", displayName: "Sonnet 5"),
                MobileTaskAgentModel(id: "claude-haiku-4-5", displayName: "Haiku 4.5"),
            ]
        case .codex:
            [
                MobileTaskAgentModel(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna"),
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

    /// Validates a model identifier against this provider's curated list.
    /// - Parameter id: CLI model identifier to validate.
    /// - Returns: The matching curated model, or `nil` when it is unavailable.
    public func model(id: String) -> MobileTaskAgentModel? {
        models.first { $0.id == id }
    }

    /// Applies a model selection to the command.
    ///
    /// When the command already carries one of this provider's model flags
    /// (before any standalone `--` end-of-options token), its value is replaced
    /// in place so the template's own spelling never overrides the explicit
    /// selection. Otherwise the flag is inserted immediately after the first
    /// token. Everything else remains byte-for-byte identical. Flag values are
    /// matched as whitespace-delimited tokens; quoted values containing
    /// whitespace are not rewritten (no model identifier contains whitespace).
    /// - Parameters:
    ///   - modelID: CLI model identifier to single-quote for the flag value.
    ///   - command: User-authored task-template command.
    /// - Returns: The command running the selected model.
    public func command(applying modelID: String, to command: String) -> String {
        guard let firstToken = Self.tokenRange(in: command, from: command.startIndex) else {
            return command
        }
        let quotedID = "'\(modelID.replacingOccurrences(of: "'", with: "'\\''"))'"

        var searchStart = firstToken.upperBound
        while let token = Self.tokenRange(in: command, from: searchStart) {
            searchStart = token.upperBound
            let text = command[token]
            if text == "--" { break }
            if modelFlagSpellings.contains(where: { text == $0 }) {
                guard let value = Self.tokenRange(in: command, from: token.upperBound) else {
                    return "\(command) \(quotedID)"
                }
                return command.replacingCharacters(in: value, with: quotedID)
            }
            if let spelling = modelFlagSpellings.first(where: { text.hasPrefix("\($0)=") }) {
                return command.replacingCharacters(in: token, with: "\(spelling)=\(quotedID)")
            }
        }

        let flag = modelFlagSpellings[0]
        return "\(command[..<firstToken.upperBound]) \(flag) \(quotedID)\(command[firstToken.upperBound...])"
    }

    /// Model-flag spellings this provider's CLI accepts; the first is used
    /// when inserting a new flag.
    private var modelFlagSpellings: [String] {
        switch self {
        case .claude:
            ["--model"]
        case .codex:
            ["-m", "--model"]
        case .openCode:
            ["--model", "-m"]
        }
    }

    private static func tokenRange(
        in command: String,
        from index: String.Index
    ) -> Range<String.Index>? {
        guard let start = command[index...].firstIndex(where: { !$0.isWhitespace }) else {
            return nil
        }
        let end = command[start...].firstIndex(where: \.isWhitespace) ?? command.endIndex
        return start..<end
    }
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
