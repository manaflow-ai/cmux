import Foundation

/// Known coding-agent CLIs the composer can offer model choices for.
///
/// Model catalogs are supplied at runtime by the selected Mac or cmux's
/// backend. This type owns only provider detection and model-flag spelling.
public enum MobileTaskAgentProvider: String, CaseIterable, Sendable {
    /// Anthropic's Claude Code CLI.
    case claude
    /// OpenAI's Codex CLI.
    case codex
    /// The OpenCode CLI.
    case openCode = "opencode"

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
        applyingOption(
            applyingOptionValue: modelID,
            flagSpellings: modelFlagSpellings,
            to: command
        )
    }

    /// Applies one model-specific effort selection to the command.
    ///
    /// The effort value is supplied by the selected model's live catalog.
    /// This type owns only each provider's CLI spelling and never invents a
    /// provider-wide set of possible values.
    public func command(applyingEffort effortID: String, to command: String) -> String {
        switch self {
        case .claude:
            applyingOption(
                applyingOptionValue: effortID,
                flagSpellings: ["--effort"],
                to: command
            )
        case .codex:
            applyingCodexEffort(effortID, to: command)
        case .openCode:
            applyingOption(
                applyingOptionValue: effortID,
                flagSpellings: ["--variant"],
                to: command
            )
        }
    }

    private func applyingOption(
        applyingOptionValue optionValue: String,
        flagSpellings: [String],
        to command: String
    ) -> String {
        guard let firstToken = Self.tokenRange(in: command, from: command.startIndex) else {
            return command
        }
        let quotedValue = Self.shellQuoted(optionValue)

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
            // An unquoted # at the start of a word begins a comment running to
            // the end of the line; nothing after it is an executable flag, and
            // the newline stop above already ends the scan there.
            if text.hasPrefix("#") { break }
            // An unquoted ;, |, or & ends the simple command, but the token's
            // prefix before it (e.g. `--model=old;`) is still ordinary flag
            // syntax that must be processed so the stale value cannot win.
            let boundary = Self.unquotedCommandBoundaryIndex(in: text)
            let word = boundary.map { text[..<$0] } ?? text
            if flagSpellings.contains(where: { word == $0 }) {
                if let boundary {
                    // `--model;`: supply the value before the separator.
                    edits.append((boundary..<boundary, " \(quotedValue)"))
                    break
                }
                if let value = Self.tokenRange(in: command, from: token.upperBound),
                   !command[token.upperBound..<value.lowerBound].contains(where: \.isNewline),
                   command[value] != "--" {
                    let valueText = command[value]
                    if let valueBoundary = Self.unquotedCommandBoundaryIndex(in: valueText) {
                        // `--model old;`: replace only the value before the
                        // separator so no stale positional argument remains.
                        edits.append((value.lowerBound..<valueBoundary, quotedValue))
                        break
                    }
                    edits.append((value, quotedValue))
                    searchStart = value.upperBound
                } else {
                    // Dangling flag (at the end of the simple command):
                    // supply the value right after the flag token.
                    edits.append((token.upperBound..<token.upperBound, " \(quotedValue)"))
                }
                continue
            }
            if let spelling = flagSpellings.first(where: { word.hasPrefix("\($0)=") }) {
                edits.append((token.lowerBound..<word.endIndex, "\(spelling)=\(quotedValue)"))
            }
            if boundary != nil { break }
        }
        if !edits.isEmpty {
            var replaced = command
            for edit in edits.reversed() {
                replaced.replaceSubrange(edit.range, with: edit.replacement)
            }
            return replaced
        }

        let flag = flagSpellings[0]
        return "\(command[..<firstToken.upperBound]) \(flag) \(quotedValue)\(command[firstToken.upperBound...])"
    }

    private func applyingCodexEffort(_ effortID: String, to command: String) -> String {
        guard let firstToken = Self.tokenRange(in: command, from: command.startIndex) else {
            return command
        }
        let replacement = "model_reasoning_effort=\(Self.shellQuoted(effortID))"
        var edits: [(range: Range<String.Index>, replacement: String)] = []
        var searchStart = firstToken.upperBound
        while let token = Self.tokenRange(in: command, from: searchStart) {
            if command[searchStart..<token.lowerBound].contains(where: \.isNewline) { break }
            searchStart = token.upperBound
            let text = command[token]
            if text == "--" || text.hasPrefix("#") { break }
            let boundary = Self.unquotedCommandBoundaryIndex(in: text)
            let word = boundary.map { text[..<$0] } ?? text
            if word.hasPrefix("--config=model_reasoning_effort=") {
                edits.append((token.lowerBound..<word.endIndex, "--config=\(replacement)"))
            }
            if boundary != nil { break }
            guard text == "-c" || text == "--config" else { continue }
            guard let value = Self.tokenRange(in: command, from: token.upperBound),
                  !command[token.upperBound..<value.lowerBound].contains(where: \.isNewline)
            else { break }
            let valueText = command[value]
            let valueBoundary = Self.unquotedCommandBoundaryIndex(in: valueText)
            let valueWord = valueBoundary.map { valueText[..<$0] } ?? valueText
            if valueWord.hasPrefix("model_reasoning_effort=") {
                edits.append((value.lowerBound..<valueWord.endIndex, replacement))
            }
            searchStart = value.upperBound
            if valueBoundary != nil { break }
        }
        if !edits.isEmpty {
            var replaced = command
            for edit in edits.reversed() {
                replaced.replaceSubrange(edit.range, with: edit.replacement)
            }
            return replaced
        }
        return "\(command[..<firstToken.upperBound]) -c \(replacement)\(command[firstToken.upperBound...])"
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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

    /// The index of the first unquoted control operator (`;`, pipe `|`, or
    /// `&`) in the token, i.e. where the first simple command ends mid-token
    /// (`"$PROMPT";`, `&&`, `--model=old;`). Redirection operators are NOT
    /// boundaries: `&` adjacent to `>` (`2>&1`, `>&2`, `&>file`) and `|`
    /// preceded by `>` (`>|file`) are part of the simple command. `nil` when
    /// the token carries no command boundary.
    private static func unquotedCommandBoundaryIndex(
        in token: Substring
    ) -> Substring.Index? {
        var inSingleQuotes = false
        var inDoubleQuotes = false
        var previousCharacter: Character?
        var current = token.startIndex
        while current < token.endIndex {
            let character = token[current]
            if character == "\\", !inSingleQuotes {
                current = token.index(after: current)
                if current < token.endIndex {
                    previousCharacter = token[current]
                    current = token.index(after: current)
                }
                continue
            }
            if character == "'", !inDoubleQuotes {
                inSingleQuotes.toggle()
            } else if character == "\"", !inSingleQuotes {
                inDoubleQuotes.toggle()
            } else if !inSingleQuotes, !inDoubleQuotes {
                let next = token.index(after: current)
                let nextCharacter = next < token.endIndex ? token[next] : nil
                switch character {
                case ";":
                    return current
                case "|" where previousCharacter != ">":
                    return current
                case "&" where previousCharacter != ">" && nextCharacter != ">":
                    return current
                default:
                    break
                }
            }
            previousCharacter = character
            current = token.index(after: current)
        }
        return nil
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
    /// Effort values reported for this exact model, in provider order.
    public let efforts: [MobileTaskAgentEffort]
    /// Provider-reported default effort, when it names one of `efforts`.
    public let defaultEffortID: String?

    /// Creates a selectable coding-agent model.
    /// - Parameters:
    ///   - id: CLI identifier passed to the provider's model flag.
    ///   - displayName: Product name displayed verbatim in the composer.
    public init(
        id: String,
        displayName: String,
        efforts: [MobileTaskAgentEffort] = [],
        defaultEffortID: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.efforts = efforts
        self.defaultEffortID = efforts.contains { $0.id == defaultEffortID }
            ? defaultEffortID
            : nil
    }
}

/// One effort choice reported for one exact coding-agent model.
public struct MobileTaskAgentEffort: Equatable, Sendable, Identifiable {
    /// CLI value passed to the provider's effort or variant flag.
    public let id: String
    /// Product name displayed verbatim in the composer.
    public let displayName: String
    /// Optional provider-authored explanation of the tradeoff.
    public let description: String?

    public init(id: String, displayName: String, description: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.description = description
    }
}
