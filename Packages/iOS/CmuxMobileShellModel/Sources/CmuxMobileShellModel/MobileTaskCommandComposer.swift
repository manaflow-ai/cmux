import Foundation

/// Composes shell-safe task startup parameters from templates and user prompts.
public struct MobileTaskCommandComposer: Sendable {
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
        let initialCommand: String
        if interpolation.didReplacePrompt {
            initialCommand = interpolation.command
        } else if !prompt.isEmpty {
            initialCommand = command + " \"${CMUX_TASK_PROMPT}\""
        } else {
            initialCommand = command
        }

        let env = interpolation.didReplacePrompt || !prompt.isEmpty
            ? ["CMUX_TASK_PROMPT": prompt]
            : [:]
        return MobileTaskComposition(initialCommand: initialCommand, initialEnv: env, title: title)
    }

    /// Replaces unescaped `{prompt}` placeholders with an environment expansion
    /// that is safe in the placeholder's current POSIX shell quote context.
    private static func interpolatingPromptEnvironment(in command: String) -> (command: String, didReplacePrompt: Bool) {
        enum Quote {
            case unquoted
            case single
            case double
        }

        var output = ""
        var index = command.startIndex
        var quote = Quote.unquoted
        var escaped = false
        var didReplacePrompt = false

        while index < command.endIndex {
            if !escaped, command[index...].hasPrefix("{prompt}") {
                switch quote {
                case .unquoted:
                    output += "\"${CMUX_TASK_PROMPT}\""
                case .single:
                    output += "'\"${CMUX_TASK_PROMPT}\"'"
                case .double:
                    output += "${CMUX_TASK_PROMPT}"
                }
                index = command.index(index, offsetBy: "{prompt}".count)
                didReplacePrompt = true
                continue
            }

            let character = command[index]
            output.append(character)
            if escaped {
                escaped = false
            } else {
                switch (quote, character) {
                case (.unquoted, "\\"), (.double, "\\"):
                    escaped = true
                case (.unquoted, "'"):
                    quote = .single
                case (.unquoted, "\""):
                    quote = .double
                case (.single, "'"):
                    quote = .unquoted
                case (.double, "\""):
                    quote = .unquoted
                default:
                    break
                }
            }
            index = command.index(after: index)
        }
        return (output, didReplacePrompt)
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
