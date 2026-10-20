/// A reasoning/thinking block the agent produced before responding.
///
/// Renders as a compact "Thought" marker in the mobile transcript. Sourced
/// from claude `thinking` content blocks and codex `reasoning` items.
public struct ChatThought: Sendable, Equatable, Codable {
    /// The reasoning text, possibly summarized by the agent runtime.
    public let text: String

    /// Creates a thought block.
    ///
    /// - Parameter text: The reasoning text.
    public init(text: String) {
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case text
    }
}
