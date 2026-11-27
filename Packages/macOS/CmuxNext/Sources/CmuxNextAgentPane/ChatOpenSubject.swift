import Foundation

/// The chat as Open Chat names it (the index's metadata).
public nonisolated struct ChatOpenSubject: Equatable, Sendable {
    public var title: String?
    /// The index harness id (`claude-code`, `codex`, `opencode`, `pi`, ...).
    public var harness: String?
    public var sessionID: String?
    public var cwd: String?
    /// The chat's index key (`harness:id`): a fresh chat opened for it shows its past turns.
    public var key: String?

    public init(title: String?, harness: String?, sessionID: String?, cwd: String?, key: String?) {
        self.title = title
        self.harness = harness
        self.sessionID = sessionID
        self.cwd = cwd
        self.key = key
    }

    /// The acpmux harness family a fresh agent chat for this chat starts on, nil for the default.
    public var acpHarness: String? {
        switch harness {
        case "claude-code": "claude"
        case "codex", "opencode", "gemini", "pi": harness
        case "cursor-agent": "cursor"
        default: nil
        }
    }

    /// Whether `key` names a chat acpmux can show without running it (View Only, acpmux
    /// `hub/watch.rs`): a Claude Code or Codex index key, `claude-code:<id>` or `codex:<id>`.
    public static func isWatchable(key: String) -> Bool {
        guard key.count <= 512, let colon = key.firstIndex(of: ":") else { return false }
        return ["claude-code", "codex"].contains(String(key[..<colon])) && key.index(after: colon) < key.endIndex
    }
}
