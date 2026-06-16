/// A transcript message plus the rendering attributes computed by the
/// projector (grouping, timestamp visibility).
public struct ChatMessageRowSnapshot: Sendable, Equatable {
    /// The message to render.
    public let message: ChatMessage

    /// Where the message sits inside its visual bubble group.
    public let groupPosition: ChatGroupPosition

    /// Whether this row shows the group's timestamp (last row of a group).
    public let showsTimestamp: Bool

    /// Creates a row snapshot.
    ///
    /// - Parameters:
    ///   - message: The message to render.
    ///   - groupPosition: Position inside the visual bubble group.
    ///   - showsTimestamp: Whether this row shows the group timestamp.
    public init(message: ChatMessage, groupPosition: ChatGroupPosition, showsTimestamp: Bool) {
        self.message = message
        self.groupPosition = groupPosition
        self.showsTimestamp = showsTimestamp
    }
}
