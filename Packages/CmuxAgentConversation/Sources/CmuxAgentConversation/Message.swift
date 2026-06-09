public import Foundation

/// One turn in an agent ``Conversation``: a role plus ordered content blocks.
///
/// A message maps to one transcript line for most roles. Tool calls and tool
/// results stay as separate messages (linked by ``Message/toolCallID``) rather
/// than being merged, so the model is a faithful, append-only projection of the
/// transcript and a view layer owns call/result pairing.
public struct Message: Codable, Hashable, Sendable, Identifiable {
    /// A stable identifier for this message within its conversation.
    public let id: String

    /// Who authored this message and how to render it.
    public let role: MessageRole

    /// The ordered content of the message.
    public let blocks: [ContentBlock]

    /// When the message was recorded, if the transcript carried a timestamp.
    public let timestamp: Date?

    /// For ``MessageRole/toolResult`` messages, the id of the call this result
    /// answers; otherwise `nil`.
    public let toolCallID: String?

    /// Creates a message.
    ///
    /// - Parameters:
    ///   - id: A stable identifier for the message within its conversation.
    ///   - role: Who authored the message.
    ///   - blocks: The ordered content blocks.
    ///   - timestamp: When the message was recorded, if known.
    ///   - toolCallID: For tool-result messages, the call id being answered.
    public init(
        id: String,
        role: MessageRole,
        blocks: [ContentBlock],
        timestamp: Date? = nil,
        toolCallID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.timestamp = timestamp
        self.toolCallID = toolCallID
    }
}
