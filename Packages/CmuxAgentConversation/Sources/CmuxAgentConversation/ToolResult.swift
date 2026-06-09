import Foundation

/// The result returned to the agent from a tool it invoked.
///
/// Stored separately from the originating ``ToolUse`` and linked by
/// ``ToolResult/toolUseID``. Keeping the two as distinct nodes (rather than
/// pre-merging them) lets a view projection pair them, while a parser that only
/// ever sees the result still produces a faithful node.
public struct ToolResult: Codable, Hashable, Sendable {
    /// The id of the ``ToolUse`` this result answers (Claude `tool_use_id`,
    /// Codex `call_id`).
    public let toolUseID: String

    /// The result content. Usually a single ``ContentBlock/text(_:)``, but tool
    /// results can also carry images or multiple blocks.
    public let blocks: [ContentBlock]

    /// Whether the tool reported an error (Claude `is_error`). Codex does not
    /// flag errors structurally, so this is `false` for Codex results.
    public let isError: Bool

    /// Creates a tool-result node.
    ///
    /// - Parameters:
    ///   - toolUseID: The id of the ``ToolUse`` this result answers.
    ///   - blocks: The result content blocks.
    ///   - isError: Whether the tool reported an error.
    public init(toolUseID: String, blocks: [ContentBlock], isError: Bool = false) {
        self.toolUseID = toolUseID
        self.blocks = blocks
        self.isError = isError
    }
}
