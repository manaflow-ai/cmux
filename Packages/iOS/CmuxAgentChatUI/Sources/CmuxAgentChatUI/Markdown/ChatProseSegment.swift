/// One renderable run of agent prose: markdown text or a fenced code block.
public struct ChatProseSegment: Sendable, Equatable, Identifiable {
    /// What the run contains.
    public enum Kind: Sendable, Equatable {
        /// Markdown-capable prose text.
        case text
        /// A fenced code block, with the fence's language tag when present.
        case code(language: String?)
    }

    /// Position of the segment within its message, for stable identity.
    public let index: Int

    /// What the run contains.
    public let kind: Kind

    /// The run's raw content (fences stripped for code segments).
    public let content: String

    /// Stable identity within the message.
    public var id: Int { index }

    /// Creates a prose segment.
    ///
    /// - Parameters:
    ///   - index: Position within the message.
    ///   - kind: What the run contains.
    ///   - content: Raw content, fences stripped for code.
    public init(index: Int, kind: Kind, content: String) {
        self.index = index
        self.kind = kind
        self.content = content
    }
}
