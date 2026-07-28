/// One normalized, harness-neutral conversation turn.
public struct ConversationTurn: Equatable, Sendable {
    /// Stable ordering identity assigned by the source reader.
    public let id: Int
    /// The semantic speaker or event role.
    public let role: ConversationRole
    /// Plain-text content with provider-specific envelopes removed.
    public let text: String

    /// Creates a normalized conversation turn.
    /// - Parameters:
    ///   - id: Stable ordering identity assigned by the source reader.
    ///   - role: The semantic speaker or event role.
    ///   - text: Plain-text content with provider-specific envelopes removed.
    public init(id: Int, role: ConversationRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}
