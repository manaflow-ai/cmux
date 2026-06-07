public import CmuxAgentConversation

/// An immutable value describing a plain message bubble.
///
/// Carries the already-flattened display text and the role so the row view does
/// no model traversal of its own. Images are noted as a count for P1 (the bytes
/// are referenced, not loaded); P3 renders them.
public struct MessageBubbleSnapshot: Hashable, Sendable {
    /// The author/category that selects styling and alignment.
    public let role: MessageRole

    /// The flattened text content of the message.
    public let text: String

    /// The number of referenced images in the message (rendered as a note in P1).
    public let imageCount: Int

    /// Creates a message-bubble snapshot.
    ///
    /// - Parameters:
    ///   - role: The author/category.
    ///   - text: The flattened text content.
    ///   - imageCount: The number of referenced images.
    public init(role: MessageRole, text: String, imageCount: Int) {
        self.role = role
        self.text = text
        self.imageCount = imageCount
    }
}
