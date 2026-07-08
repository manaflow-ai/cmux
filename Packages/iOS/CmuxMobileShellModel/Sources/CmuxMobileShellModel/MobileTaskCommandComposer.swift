import Foundation

/// Composes shell-safe task startup parameters from templates and user prompts.
public struct MobileTaskCommandComposer: Sendable {
    /// Creates a command composer.
    public init() {}

    /// Returns a shell single-quoted representation of `value`.
    /// - Parameter value: Raw value to quote for shell interpretation.
    /// - Returns: A single-quoted shell token.
    func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

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

        let initialCommand: String
        if command.contains("{prompt}") {
            initialCommand = command.replacingOccurrences(of: "{prompt}", with: shellQuoted(prompt))
        } else if !prompt.isEmpty {
            initialCommand = command + " " + shellQuoted(prompt)
        } else {
            initialCommand = command
        }

        let env = prompt.isEmpty ? [:] : ["CMUX_TASK_PROMPT": prompt]
        return MobileTaskComposition(initialCommand: initialCommand, initialEnv: env, title: title)
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
