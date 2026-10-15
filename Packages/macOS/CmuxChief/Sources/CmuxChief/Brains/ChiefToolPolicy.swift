import Foundation

/// What a Chief may do without asking, and how its tool calls read in Home.
///
/// Auto-allowed without an approval card:
///
/// - Claude Code's read-only tools: `Read`, `Glob`, `Grep`, `WebSearch`,
///   `WebFetch`, `ToolSearch`.
/// - A shell command that is one simple command (no `;`, `&&`, `|`,
///   redirection or substitution) starting with `cmux`, or one of a few
///   read-only commands: `ls`, `pwd`, `cat`, `head`, `tail`, `wc`, `which`,
///   `date`, `git status|log|diff|show|branch`, `gh issue view|list`,
///   `gh pr view|list|diff|checks`.
///
/// Everything else (edits, writes, other commands) asks the user.
enum ChiefToolPolicy {
    /// The options of every approval card, allow first.
    static let approvalOptions = ["Allow", "Deny"]

    /// Whether a choice from ``approvalOptions`` grants the call.
    static func isAllow(_ choice: String) -> Bool {
        choice.caseInsensitiveCompare("Allow") == .orderedSame
    }

    private static let readOnlyTools: Set<String> = ["Read", "Glob", "Grep", "WebSearch", "WebFetch", "ToolSearch"]
    private static let readOnlyPrograms: Set<String> = ["ls", "pwd", "cat", "head", "tail", "wc", "which", "date"]
    private static let readOnlySubcommands: [String: Set<String>] = [
        "git": ["status", "log", "diff", "show", "branch"],
    ]
    private static let readOnlyGitHub: [String: Set<String>] = [
        "issue": ["view", "list"],
        "pr": ["view", "list", "diff", "checks"],
    ]

    /// Whether Claude Code's `tool` with `input` runs without asking.
    ///
    /// - Parameters:
    ///   - tool: The tool name from the permission request.
    ///   - input: The tool's input.
    static func autoAllowsClaudeTool(_ tool: String, input: ChiefJSON) -> Bool {
        if readOnlyTools.contains(tool) { return true }
        if tool == "Bash", let command = input["command"]?.string { return autoAllowsCommand(command) }
        return false
    }

    /// Whether a shell command runs without asking.
    ///
    /// - Parameter command: The command line, possibly wrapped in `sh -lc '…'`.
    static func autoAllowsCommand(_ command: String) -> Bool {
        let line = unwrapShell(command).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }
        let chaining = [";", "&", "|", "`", "$(", ">", "<", "\n", "\r"]
        if chaining.contains(where: { line.contains($0) }) { return false }
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // A bare program name only: `/tmp/x/cmux` is not the cmux CLI.
        guard let program = words.first else { return false }
        if program == "cmux" { return true }
        if readOnlyPrograms.contains(program) { return true }
        if let allowed = readOnlySubcommands[program], words.count > 1 { return allowed.contains(words[1]) }
        if program == "gh", words.count > 2, let allowed = readOnlyGitHub[words[1]] { return allowed.contains(words[2]) }
        return false
    }

    /// The inner command of `bash -lc '…'`, `zsh -c "…"` and the like, or
    /// `command` itself.
    static func unwrapShell(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let shells = ["sh", "bash", "zsh"]
        for shell in shells {
            for prefix in ["/bin/\(shell) ", "/usr/bin/\(shell) ", "\(shell) "] {
                for flag in ["-lc ", "-c "] where trimmed.hasPrefix(prefix + flag) {
                    let inner = String(trimmed.dropFirst(prefix.count + flag.count))
                    return stripQuotes(inner)
                }
            }
        }
        return trimmed
    }

    private static func stripQuotes(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, let first = trimmed.first, first == trimmed.last, first == "'" || first == "\"" else {
            return trimmed
        }
        let inner = String(trimmed.dropFirst().dropLast())
        // A quote inside means the wrapper held more than one simple string.
        return inner.contains(first) ? trimmed : inner
    }

    /// A short title for a Claude Code tool call, such as the `description`
    /// of a `Bash` call or `Read Sources/App.swift`.
    ///
    /// - Parameters:
    ///   - tool: The tool name.
    ///   - input: The tool's input.
    static func claudeTitle(_ tool: String, input: ChiefJSON) -> String {
        let text: String
        switch tool {
        case "Bash":
            text = nonEmpty(input["description"]?.string) ?? input["command"]?.string ?? "Run a command"
        case "Read":
            text = "Read " + (input["file_path"]?.string ?? "a file")
        case "Write":
            text = "Write " + (input["file_path"]?.string ?? "a file")
        case "Edit", "MultiEdit":
            text = "Edit " + (input["file_path"]?.string ?? "a file")
        case "Glob", "Grep":
            text = "Search " + (input["pattern"]?.string ?? "files")
        case "WebFetch":
            text = "Fetch " + (input["url"]?.string ?? "a page")
        case "WebSearch":
            text = "Search the web: " + (input["query"]?.string ?? "")
        case "ToolSearch":
            text = "Find tools"
        default:
            // MCP tools are `mcp__server__tool`; the last part reads best.
            let parts = tool.components(separatedBy: "__")
            text = parts.count >= 3 ? parts.dropFirst(2).joined(separator: "__") : tool
        }
        return truncate(text.replacingOccurrences(of: "\n", with: " "), to: 80)
    }

    /// The full input of a tool call for its work card: the command for a
    /// shell call, compact JSON otherwise.
    static func claudeDetail(_ tool: String, input: ChiefJSON) -> String? {
        if tool == "Bash", let command = input["command"]?.string { return command }
        if case .object(let members) = input, members.isEmpty { return nil }
        return truncate(input.compactText, to: 4000)
    }

    /// The approval prompt for a Claude Code permission request.
    static func claudePrompt(_ tool: String, input: ChiefJSON) -> String {
        if tool == "Bash", let command = input["command"]?.string {
            return "Run `\(truncate(command, to: 300))`?"
        }
        return "Allow \(claudeTitle(tool, input: input))?"
    }

    /// The first few lines of a tool result, for a finished work card.
    ///
    /// - Parameter text: The tool's output.
    /// - Returns: Up to 3 lines and 240 characters, nil for empty output.
    static func preview(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).prefix(3)
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : truncate(joined, to: 240)
    }

    /// `text` cut to `limit` characters with an ellipsis.
    static func truncate(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text
    }
}
