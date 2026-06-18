/// Conversational text content: a user prompt or agent prose.
///
/// `text` is markdown-capable for agent messages; user prompts are treated
/// as plain text by renderers.
public struct ChatProse: Sendable, Equatable, Codable {
    /// The message text. Agent-authored text may contain markdown.
    public let text: String

    /// Creates prose content.
    ///
    /// - Parameter text: The message text, markdown-capable for agents.
    public init(text: String) {
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case text
    }
}
