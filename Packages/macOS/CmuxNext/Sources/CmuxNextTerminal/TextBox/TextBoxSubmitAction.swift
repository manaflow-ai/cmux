package import Foundation

/// What Return does with the TextBox's text: send it as typed (text entry), or start an agent
/// with it as the prompt (a command template whose `{{prompt}}` takes the text, shell-quoted).
package nonisolated struct TextBoxSubmitAction: Equatable, Identifiable, Sendable {
    package let id: String
    package let title: String
    /// SF Symbol shown on the action button.
    package let symbol: String
    /// The command line with `{{prompt}}`; nil sends the text itself.
    package let template: String?

    package static let textEntry = TextBoxSubmitAction(id: "text-entry", title: TextBoxStrings.textEntry, symbol: "arrow.up", template: nil)

    /// Text entry first, then the agents of the shipping cmux, in its order (Shift-Tab cycles).
    package static let catalog: [TextBoxSubmitAction] = [
        textEntry,
        TextBoxSubmitAction(id: "claude", title: "Claude", symbol: "sparkle", template: "claude --dangerously-skip-permissions -- {{prompt}}"),
        TextBoxSubmitAction(id: "codex", title: "Codex", symbol: "sparkles", template: "codex --yolo -- {{prompt}}"),
        TextBoxSubmitAction(id: "opencode", title: "OpenCode", symbol: "curlybraces", template: "opencode --prompt {{prompt}}"),
        TextBoxSubmitAction(id: "pi", title: "Pi", symbol: "brain.head.profile", template: "pi -- {{prompt}}"),
    ]

    /// What goes to the terminal for `prompt`: the text, or the command with the trimmed text quoted.
    package func input(for prompt: String) -> String {
        guard let template else { return prompt }
        return template.replacingOccurrences(of: "{{prompt}}", with: Self.quoted(prompt.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// `text` in single quotes for a POSIX shell (a quote inside becomes `'\''`).
    package static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
