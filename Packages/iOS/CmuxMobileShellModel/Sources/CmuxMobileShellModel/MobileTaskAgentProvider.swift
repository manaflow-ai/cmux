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
    /// compound or environment-prefixed commands detect no provider. Detection
    /// fails closed: an undetected command offers no model UI and always runs
    /// byte-for-byte verbatim.
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
    /// When the first simple command already carries one of this provider's
    /// model flags, every such flag's value is replaced in place so the
    /// template's own spelling never overrides the explicit selection.
    /// Otherwise the flag is inserted immediately after the first token.
    /// Everything else remains byte-for-byte identical. Tokenization is
    /// quote-aware (single quotes, double quotes, and backslash escapes
    /// outside single quotes), so flag text embedded in a quoted argument is
    /// never rewritten, and scanning stops at the first simple command's end:
    /// a standalone `--` end-of-options token, an unquoted `;`, `|`, or `&`,
    /// or a newline. Shell comments, subshells, and heredocs are not parsed.
    /// - Parameters:
    ///   - modelID: CLI model identifier to single-quote for the flag value.
    ///   - command: User-authored task-template command.
    /// - Returns: The command running the selected model.
    public func command(applying modelID: String, to command: String) -> String {
        guard let firstToken = Self.tokenRange(in: command, from: command.startIndex) else {
            return command
        }
        let quotedID = "'\(modelID.replacingOccurrences(of: "'", with: "'\\''"))'"

        // Collect edits against the immutable command, then apply back to
        // front so earlier ranges stay valid.
        var edits: [(range: Range<String.Index>, replacement: String)] = []
        var searchStart = firstToken.upperBound
        while let token = Self.tokenRange(in: command, from: searchStart) {
            // A newline between tokens ends the first simple command.
            if command[searchStart..<token.lowerBound].contains(where: \.isNewline) { break }
            searchStart = token.upperBound
            let text = command[token]
            if text == "--" { break }
            if Self.containsUnquotedCommandBoundary(text) { break }
            if modelFlagSpellings.contains(where: { text == $0 }) {
                if let value = Self.tokenRange(in: command, from: token.upperBound),
                   !command[token.upperBound..<value.lowerBound].contains(where: \.isNewline),
                   command[value] != "--",
                   !Self.containsUnquotedCommandBoundary(command[value]) {
                    edits.append((value, quotedID))
                    searchStart = value.upperBound
                } else {
                    // Dangling flag (at the end of the simple command):
                    // supply the value right after the flag token.
                    edits.append((token.upperBound..<token.upperBound, " \(quotedID)"))
                }
                continue
            }
            if let spelling = modelFlagSpellings.first(where: { text.hasPrefix("\($0)=") }) {
                edits.append((token, "\(spelling)=\(quotedID)"))
            }
        }
        if !edits.isEmpty {
            var replaced = command
            for edit in edits.reversed() {
                replaced.replaceSubrange(edit.range, with: edit.replacement)
            }
            return replaced
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

    /// Whether the token carries an unquoted `;`, `|`, or `&`, i.e. ends the
    /// first simple command mid-token (`"$PROMPT";`, `&&`, `|`).
    private static func containsUnquotedCommandBoundary(_ token: Substring) -> Bool {
        var inSingleQuotes = false
        var inDoubleQuotes = false
        var current = token.startIndex
        while current < token.endIndex {
            let character = token[current]
            if character == "\\", !inSingleQuotes {
                current = token.index(after: current)
                if current < token.endIndex {
                    current = token.index(after: current)
                }
                continue
            }
            if character == "'", !inDoubleQuotes {
                inSingleQuotes.toggle()
            } else if character == "\"", !inSingleQuotes {
                inDoubleQuotes.toggle()
            } else if !inSingleQuotes, !inDoubleQuotes,
                      character == ";" || character == "|" || character == "&" {
                return true
            }
            current = token.index(after: current)
        }
        return false
    }

    /// The next shell word starting at or after `index`. Quote-aware: single-
    /// and double-quoted spans (and backslash escapes outside single quotes)
    /// never end a token, so flag text embedded in a quoted argument is one
    /// opaque token rather than a false flag match. An unterminated quote
    /// consumes the rest of the command.
    private static func tokenRange(
        in command: String,
        from index: String.Index
    ) -> Range<String.Index>? {
        guard let start = command[index...].firstIndex(where: { !$0.isWhitespace }) else {
            return nil
        }
        var inSingleQuotes = false
        var inDoubleQuotes = false
        var current = start
        while current < command.endIndex {
            let character = command[current]
            if character == "\\", !inSingleQuotes {
                current = command.index(after: current)
                if current < command.endIndex {
                    current = command.index(after: current)
                }
                continue
            }
            if character == "'", !inDoubleQuotes {
                inSingleQuotes.toggle()
            } else if character == "\"", !inSingleQuotes {
                inDoubleQuotes.toggle()
            } else if character.isWhitespace, !inSingleQuotes, !inDoubleQuotes {
                break
            }
            current = command.index(after: current)
        }
        return start..<current
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
