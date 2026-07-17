import Foundation

/// Composes the startup text for launching a coding agent with an initial
/// prompt in a fresh workspace terminal (the mobile `mobile.workspace.launch_agent`
/// flow). The command is typed at the login shell prompt (Ghostty
/// `initial_input`), so the agent inherits the user's shell environment exactly
/// as if they had typed it themselves.
public enum AgentPromptWorkspaceLaunch {
    /// The startup text a fresh terminal should type at its shell prompt.
    public enum StartupInput: Equatable, Sendable {
        /// The composed command fits the inline budget; type it directly
        /// (trailing newline included).
        case inline(String)
        /// The command is too large or multiline to type inline; the caller
        /// writes `body` to a script file and types `/bin/zsh '<path>'`.
        case script(body: String)
    }

    /// Same inline budget as the agent fork/resume startup-input path: typed
    /// lines beyond this go through a launcher script instead of the pty.
    public static let maxInlineBytes = 900

    /// `<executable> '<prompt>'` with both sides single-quoted for POSIX shells.
    public static func shellCommand(executablePath: String, prompt: String) -> String {
        "\(singleQuoted(executablePath)) \(singleQuoted(prompt))"
    }

    /// Inline when the command is a single line within budget; script otherwise.
    /// Multiline prompts always take the script path so the typed input never
    /// depends on the shell's quote-continuation behavior.
    public static func startupInput(command: String, maxInlineBytes: Int = maxInlineBytes) -> StartupInput {
        let inline = command + "\n"
        if !command.contains(where: \.isNewline), inline.utf8.count <= maxInlineBytes {
            return .inline(inline)
        }
        return .script(body: "#!/bin/zsh\nexec \(command)\n")
    }

    /// The typed line that runs a written launcher script.
    public static func scriptInvocation(scriptPath: String) -> String {
        "/bin/zsh \(singleQuoted(scriptPath))\n"
    }

    /// A concise workspace title derived from the prompt: first line, collapsed
    /// whitespace, cut at a word boundary. `nil` when the prompt is blank.
    public static func derivedWorkspaceTitle(prompt: String, maxLength: Int = 48) -> String? {
        let firstLine = prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        let collapsed = firstLine
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxLength else { return collapsed }
        let prefix = String(collapsed.prefix(maxLength))
        let cut = prefix.lastIndex(where: { $0 == " " }).map { String(prefix[..<$0]) } ?? prefix
        return cut + "…"
    }

    /// POSIX single-quoting: wraps in `'…'`, escaping embedded single quotes.
    public static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
