import Foundation

/// The author/category of a ``Message`` in an agent conversation.
///
/// Roles are normalized across agents: Claude Code and Codex use different raw
/// strings (`assistant` vs `output_text`-bearing `message`, `tool_result`
/// inside a `user` line vs `function_call_output`), but both map onto this
/// shared set so one view can render either transcript.
public enum MessageRole: String, Codable, Hashable, Sendable {
    /// A human prompt.
    case user

    /// Agent-authored output (text and/or tool calls).
    case assistant

    /// The result returned to the agent from a tool it invoked. Correlated to
    /// its call by ``Message/toolCallID``.
    case toolResult

    /// A system/envelope message (instructions, environment context).
    case system

    /// Agent reasoning / thinking content surfaced as its own message.
    case reasoning
}
