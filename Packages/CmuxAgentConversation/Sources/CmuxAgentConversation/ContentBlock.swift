import Foundation

/// One piece of content inside a ``Message`` or ``ToolResult``.
///
/// A message's content is an ordered list of blocks so interleaved text, tool
/// calls, reasoning, and images keep their original sequence. The enum is
/// `indirect` because ``ContentBlock/toolResult(_:)`` carries a ``ToolResult``
/// whose own blocks are `ContentBlock`s (a tool result can contain text and
/// images).
public indirect enum ContentBlock: Codable, Hashable, Sendable {
    /// Plain text.
    case text(String)

    /// A request by the agent to invoke a tool.
    case toolUse(ToolUse)

    /// The result of a tool invocation, correlated to its call by id.
    case toolResult(ToolResult)

    /// A referenced image attachment (see ``ImageRef``).
    case image(ImageRef)

    /// Agent reasoning / thinking text.
    case reasoning(String)
}
