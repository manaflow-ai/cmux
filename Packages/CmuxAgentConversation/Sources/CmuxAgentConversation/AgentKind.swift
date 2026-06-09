import Foundation

/// The coding agent that produced a transcript.
///
/// Used to pick the matching ``AgentTranscriptParsing`` implementation and to
/// label a ``Conversation`` in the UI. New agents are added as cases; the
/// ``AgentKind/unknown`` case keeps the model total when a transcript comes
/// from a source this build does not recognize.
public enum AgentKind: String, Codable, Hashable, Sendable {
    /// Anthropic's Claude Code CLI (`~/.claude/projects/<dir>/<uuid>.jsonl`).
    case claudeCode

    /// OpenAI's Codex CLI (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`).
    case codex

    /// An agent whose transcript format this build does not understand.
    case unknown
}
