import CmuxMobileAgentChat
import Foundation

/// The approval a terminal agent waits on: a Claude Code permission prompt ("Do you want to
/// proceed?") in a Mac terminal tab, not an acpmux chat. The daemon carries what the prompt
/// asks on the notification's ledger row (`approval`, memory only: cmux-tui
/// `agent_hook_live_approval`), while the agent is blocked on it, so the Feed shows it as a
/// permission card and answers it with Allow once / Deny (`TerminalApprovalKeys`).
public struct TerminalApproval: Hashable, Sendable {
    /// The tool that asks ("Bash", "Write", "WebFetch").
    public var tool: String
    /// The command it would run.
    public var command: String?
    /// The file, path or URL it would touch (no command).
    public var target: String?
    /// The agent's own words for it ("List the files").
    public var description: String?

    public init(tool: String, command: String? = nil, target: String? = nil, description: String? = nil) {
        self.tool = tool
        self.command = command
        self.target = target
        self.description = description
    }

    /// The daemon's `approval` (`{harness: "claude", tool, command?, target?, description?}`).
    /// Only Claude Code's is answerable here: its approval screen is the one mapped.
    public init?(json: [String: Any]) {
        guard json["harness"] as? String == "claude" else { return nil }
        func text(_ key: String) -> String? {
            (json[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let tool = text("tool") else { return nil }
        self.init(tool: tool, command: text("command"), target: text("target"), description: text("description"))
    }

    /// Allow once types `1`, Deny presses Escape (Claude Code: "No, and tell Claude what to do
    /// differently (esc)"). A lasting grant ("Yes, and don't ask again") is not offered from a
    /// phone, as for agent chats (`ACPPermissionRequest.phoneOptions`).
    public static let allowOnce = ACPPermissionOption(id: "terminal-allow-once", name: "Allow once", kind: .allowOnce)
    public static let deny = ACPPermissionOption(id: "terminal-deny", name: "Deny", kind: .rejectOnce)

    /// The card's request: its command shows in the command card, as an agent chat's does.
    func request(ledgerID: String, surface: Int) -> ACPPermissionRequest {
        var input: [String: JSONValue] = [:]
        if let command { input["command"] = .string(command) }
        if let target { input["path"] = .string(target) }
        if let description { input["description"] = .string(description) }
        let toolCall = ACPToolCall(
            id: "s\(surface)-\(ledgerID)", title: tool, kind: command != nil ? .execute : .other,
            status: .pending, rawInput: .object(input)
        )
        return ACPPermissionRequest(id: ledgerID, toolCall: toolCall, options: [Self.allowOnce, Self.deny])
    }

    /// The card's words above its command: what the agent wants to do.
    var markdown: String {
        var head = "**\(String(localized: "Wants to use")) \(tool)**"
        if command == nil, let target { head += ": `\(target.replacingOccurrences(of: "`", with: "'"))`" }
        guard let description else { return head }
        return head + "\n\n" + description
    }
}

/// The keys that answer Claude Code's approval screen on its own terminal, as a person would
/// press them. Read live from Claude Code 2.1.328 (verify/push-matrix-terminal-questions.md,
/// "Terminal approvals"):
///
/// ```
///  Bash command
///    ls -la /tmp/x
///    List files
///  Do you want to proceed?
///  ❯ 1. Yes
///    2. Yes, and don't ask again for ls commands in /tmp/x
///    3. No, and tell Claude what to do differently (esc)
/// ```
///
/// A row's number chooses it at once; Escape is the No row.
public enum TerminalApprovalKeys {
    static let escape = "\u{1b}"

    /// The keys for `option`: `1` for Allow once, Escape for Deny.
    public static func keys(_ option: ACPPermissionOption) -> [Data] {
        [Data((option.kind == .allowOnce ? "1" : escape).utf8)]
    }

    /// Whether `screen` (the terminal's text now) shows this approval waiting: Claude Code's
    /// question line, its first row "1. Yes", and the start of the command (or the path) it
    /// asks about. Keys go out only then, so a `1` never lands in another prompt or a shell.
    public static func screenShows(_ screen: String, approval: TerminalApproval) -> Bool {
        let compact = { (text: String) in text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let shown = compact(screen)
        guard shown.contains("Do you want to"), shown.contains("1. Yes") else { return false }
        // The prompt wraps and cuts long commands: the first line's start is what stays shown.
        if let subject = approval.command ?? approval.target {
            let first = subject.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? subject
            let start = compact(String(first.prefix(40)))
            if !start.isEmpty, !shown.contains(start) { return false }
        }
        return true
    }
}
