import Foundation

/// The coding-agent transcript formats whose usage cmux can sample.
///
/// Only agents whose on-disk transcript records per-request token usage are
/// listed; every other hook source yields `nil` from ``init(hookSource:)``.
public enum AgentUsageSource: String, Sendable, Equatable, Hashable, CaseIterable {
    /// Claude Code JSONL transcripts: `assistant` lines carry `message.model`
    /// and `message.usage`.
    case claude
    /// Codex rollout JSONL: `turn_context` lines carry `model` and
    /// `event_msg` `token_count` lines carry cumulative and last-request usage.
    case codex

    /// Maps a hook event `_source` string to a usage source.
    ///
    /// - Parameter hookSource: The hook event source (`"claude"`, `"codex"`, …).
    public init?(hookSource: String) {
        self.init(rawValue: hookSource)
    }

    /// The sidebar status-entry key the agent's hook integration writes
    /// (`claude_code` for Claude Code, `codex` for Codex).
    public var sidebarStatusKey: String {
        switch self {
        case .claude: return "claude_code"
        case .codex: return "codex"
        }
    }
}
