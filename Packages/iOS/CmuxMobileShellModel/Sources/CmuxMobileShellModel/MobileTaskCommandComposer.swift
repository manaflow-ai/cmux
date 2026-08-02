import Foundation

/// Composes task startup parameters without interpreting user-authored shell source.
public struct MobileTaskCommandComposer: Sendable {
    /// Creates a command composer.
    public init() {}

    /// Preserves a nonblank template command byte-for-byte and supplies the
    /// trimmed task prompt through `CMUX_TASK_PROMPT`. Blank commands open a
    /// plain shell and intentionally receive no startup environment.
    /// - Parameters:
    ///   - template: The selected task template.
    ///   - prompt: User-entered task prompt.
    /// - Returns: The command, environment, and prompt-derived title.
    public func compose(template: MobileTaskTemplate, prompt rawPrompt: String) -> MobileTaskComposition {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = Self.taskTitle(from: prompt)
        guard !template.isPlainShell else {
            return MobileTaskComposition(initialCommand: nil, initialEnv: [:], title: title)
        }
        return MobileTaskComposition(
            initialCommand: template.command,
            initialEnv: ["CMUX_TASK_PROMPT": prompt],
            title: title
        )
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
