import Foundation

/// Composes shell-safe task startup parameters from templates and user prompts.
public struct MobileTaskCommandComposer: Sendable {
    private enum ShellQuote {
        case unquoted
        case single
        case double
    }

    private struct ShellLexicalState {
        private(set) var quote = ShellQuote.unquoted
        private(set) var escaped = false
        private(set) var inComment = false
        private var atWordBoundary = true

        var permitsEnvironmentExpansion: Bool {
            !inComment && !escaped && quote != .single
        }

        func startsComment(with character: Character) -> Bool {
            quote == .unquoted && !escaped && character == "#" && atWordBoundary
        }

        mutating func beginComment() {
            inComment = true
        }

        mutating func markExpansion() {
            atWordBoundary = false
        }

        mutating func consume(_ character: Character) {
            if inComment {
                if character == "\n" {
                    inComment = false
                    atWordBoundary = true
                }
                return
            }
            if escaped {
                escaped = false
                atWordBoundary = false
                return
            }
            switch (quote, character) {
            case (.unquoted, "\\"), (.double, "\\"):
                escaped = true
            case (.unquoted, "'"):
                quote = .single
                atWordBoundary = false
            case (.unquoted, "\""):
                quote = .double
                atWordBoundary = false
            case (.single, "'"):
                quote = .unquoted
            case (.double, "\""):
                quote = .unquoted
            case (.unquoted, " "), (.unquoted, "\t"), (.unquoted, "\r"), (.unquoted, "\n"):
                atWordBoundary = true
            case (.unquoted, ";"), (.unquoted, "|"), (.unquoted, "&"),
                 (.unquoted, "("), (.unquoted, ")"), (.unquoted, "<"), (.unquoted, ">"):
                atWordBoundary = true
            default:
                if quote == .unquoted {
                    atWordBoundary = false
                }
            }
        }
    }

    /// Creates a command composer.
    public init() {}

    /// Composes workspace-create parameters for `template` and `prompt`.
    /// - Parameters:
    ///   - template: The selected task template.
    ///   - prompt: User-entered task prompt.
    /// - Returns: The derived command, environment, and title.
    public func compose(template: MobileTaskTemplate, prompt rawPrompt: String) -> MobileTaskComposition {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = template.command
        let title = Self.taskTitle(from: prompt)

        guard !command.isEmpty else {
            return MobileTaskComposition(initialCommand: nil, initialEnv: [:], title: title)
        }

        let interpolation = Self.interpolatingPromptEnvironment(in: command)
        let explicitlyReferencesPrompt = Self.referencesPromptEnvironment(in: command)
        let initialCommand: String
        if interpolation.didReplacePrompt {
            initialCommand = interpolation.command
        } else if explicitlyReferencesPrompt {
            initialCommand = command
        } else if !prompt.isEmpty {
            let trailingWhitespaceCount = command.reversed().prefix(while: \.isWhitespace).count
            initialCommand = String(command.dropLast(trailingWhitespaceCount)) + " -- \"${CMUX_TASK_PROMPT}\""
        } else {
            initialCommand = command
        }

        let env = interpolation.didReplacePrompt || explicitlyReferencesPrompt || !prompt.isEmpty
            ? ["CMUX_TASK_PROMPT": prompt]
            : [:]
        return MobileTaskComposition(initialCommand: initialCommand, initialEnv: env, title: title)
    }

    /// Replaces unescaped `{prompt}` placeholders with an environment expansion
    /// that is safe in the placeholder's current POSIX shell quote context.
    private static func interpolatingPromptEnvironment(in command: String) -> (command: String, didReplacePrompt: Bool) {
        var output = ""
        var index = command.startIndex
        var lexicalState = ShellLexicalState()
        var didReplacePrompt = false

        while index < command.endIndex {
            let character = command[index]
            if lexicalState.inComment {
                output.append(character)
                lexicalState.consume(character)
                index = command.index(after: index)
                continue
            }

            if lexicalState.startsComment(with: character) {
                lexicalState.beginComment()
                output.append(character)
                index = command.index(after: index)
                continue
            }

            if !lexicalState.escaped, command[index...].hasPrefix("{prompt}") {
                switch lexicalState.quote {
                case .unquoted:
                    output += "\"${CMUX_TASK_PROMPT}\""
                case .single:
                    output += "'\"${CMUX_TASK_PROMPT}\"'"
                case .double:
                    output += "${CMUX_TASK_PROMPT}"
                }
                index = command.index(index, offsetBy: "{prompt}".count)
                didReplacePrompt = true
                lexicalState.markExpansion()
                continue
            }

            output.append(character)
            lexicalState.consume(character)
            index = command.index(after: index)
        }
        return (output, didReplacePrompt)
    }

    /// The documented environment-variable form is an explicit prompt consumer,
    /// so the composer must not append a second prompt argument.
    private static func referencesPromptEnvironment(in command: String) -> Bool {
        let unbraced = "$CMUX_TASK_PROMPT"
        let braced = "${CMUX_TASK_PROMPT}"
        var lexicalState = ShellLexicalState()
        var index = command.startIndex
        while index < command.endIndex {
            let character = command[index]
            if lexicalState.inComment {
                lexicalState.consume(character)
                index = command.index(after: index)
                continue
            }
            if lexicalState.startsComment(with: character) {
                lexicalState.beginComment()
                index = command.index(after: index)
                continue
            }
            if lexicalState.permitsEnvironmentExpansion {
                if command[index...].hasPrefix(braced) {
                    return true
                }
                if command[index...].hasPrefix(unbraced) {
                    let end = command.index(index, offsetBy: unbraced.count)
                    if end == command.endIndex || !Self.isShellIdentifierCharacter(command[end]) {
                        return true
                    }
                }
            }
            lexicalState.consume(character)
            index = command.index(after: index)
        }
        return false
    }

    private static func isShellIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    /// The suggested workspace title for a task prompt: its first line, capped
    /// at 60 characters. Static (not file-scope): the package conventions lint
    /// forbids free functions in iOS package sources.
    private static func taskTitle(from prompt: String) -> String? {
        guard let firstLine = prompt.split(separator: "\n", omittingEmptySubsequences: false).first,
              !firstLine.isEmpty else {
            return nil
        }
        return String(firstLine.prefix(60))
    }
}
