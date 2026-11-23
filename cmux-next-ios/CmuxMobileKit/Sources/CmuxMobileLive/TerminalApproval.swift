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
/// "Terminal approvals"): the dialog starts at a horizontal rule, names the command (or the file,
/// "Do you want to create todo.txt?") and lists its rows:
///
/// ```
/// ──────────────────────────────
///  Bash command
///  mkdir -p out && touch out/a.txt
///  Do you want to proceed?
///  ❯ 1. Yes
///    2. Yes, and don't ask again for … commands in /tmp/x
///    3. Yes, and switch to auto mode · auto mode handles these prompts for you
///    4. No
///  Esc to cancel · Tab to amend
/// ```
///
/// A row's number chooses it at once; Escape cancels (the No row moves, Escape does not).
public enum TerminalApprovalKeys {
    static let escape = "\u{1b}"

    /// The keys for `option`: `1` for Allow once, Escape for Deny.
    public static func keys(_ option: ACPPermissionOption) -> [Data] {
        [Data((option.kind == .allowOnce ? "1" : escape).utf8)]
    }

    /// The longest part of a command matched on its dialog (characters, whitespace dropped).
    static let commandMatch = 400

    /// What the approval dialog shows of this approval, to tell it from another one: its
    /// command with every space and line break dropped (a long command wraps on a narrow
    /// terminal, in the middle of a word), or the file name of the path it touches (Claude Code
    /// asks "Do you want to create todo.txt?"). Nil when it names neither: such an approval keeps
    /// "Answer in Terminal" (any approval dialog would pass).
    static func subject(_ approval: TerminalApproval) -> String? {
        if let command = approval.command {
            let bare = String(dense(command).prefix(commandMatch))
            return bare.isEmpty ? nil : bare
        }
        guard let target = approval.target, !target.contains("://") else { return nil }
        let name = (target as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : compact(name)
    }

    static func compact(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    static func dense(_ text: String) -> String { String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }) }

    /// Whether `screen` (the terminal's text now) shows this approval waiting: Claude Code's
    /// approval dialog at the bottom of the screen, from the last horizontal rule above its
    /// "Do you want to" line down to "Esc to cancel" (the screen's last line), with "1. Yes" as
    /// the row under the question. A command must show in full above the question, a file in
    /// the question itself. The transcript above the dialog never counts (it can show an
    /// earlier command, whose stale card must never answer a newer approval), nor does text the
    /// agent wrote that merely looks like one. Keys go out only then.
    public static func screenShows(_ screen: String, approval: TerminalApproval) -> Bool {
        guard let subject = subject(approval) else { return false }
        let lines = screen.components(separatedBy: "\n")
        guard let ask = lines.lastIndex(where: { $0.contains("Do you want to") }),
              let top = lines[..<ask].lastIndex(where: { line in
                  let rule = line.trimmingCharacters(in: .whitespaces)
                  return rule.count >= 8 && rule.allSatisfy { $0 == "\u{2500}" }
              }) else { return false }
        let below = lines[(ask + 1)...].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = below.first, first.contains("1. Yes"),
              let last = below.last, last.hasPrefix("Esc to cancel") else { return false }
        if approval.command != nil {
            return dense(lines[(top + 1)..<ask].joined()).contains(subject)
        }
        return compact(lines[ask]).contains(subject)
    }
}
