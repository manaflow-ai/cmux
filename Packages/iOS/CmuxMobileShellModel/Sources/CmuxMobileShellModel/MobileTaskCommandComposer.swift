import Foundation

/// The workspace-create parameters derived from a task template and prompt.
public struct MobileTaskComposition: Equatable, Sendable {
    /// Shell-interpreted command for the initial terminal, or `nil` for a plain shell.
    public var initialCommand: String?
    /// Environment variables for the initial terminal.
    public var initialEnv: [String: String]
    /// Suggested workspace title derived from the prompt.
    public var title: String?

    /// Creates a task composition.
    /// - Parameters:
    ///   - initialCommand: Shell-interpreted command for the initial terminal.
    ///   - initialEnv: Environment variables for the initial terminal.
    ///   - title: Suggested workspace title.
    public init(initialCommand: String?, initialEnv: [String: String], title: String?) {
        self.initialCommand = initialCommand
        self.initialEnv = initialEnv
        self.title = title
    }
}

/// Composes shell-safe task startup parameters from templates and user prompts.
public struct MobileTaskCommandComposer: Sendable {
    /// Creates a command composer.
    public init() {}

    /// Returns a shell single-quoted representation of `value`.
    /// - Parameter value: Raw value to quote for shell interpretation.
    /// - Returns: A single-quoted shell token.
    public func shellQuoted(_ value: String) -> String {
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
        let title = Self.title(from: prompt)

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

    private static func title(from prompt: String) -> String? {
        guard let firstLine = prompt.split(separator: "\n", omittingEmptySubsequences: false).first,
              !firstLine.isEmpty else {
            return nil
        }
        return String(firstLine.prefix(60))
    }
}
