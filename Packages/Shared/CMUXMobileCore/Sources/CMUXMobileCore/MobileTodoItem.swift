/// One bounded checklist item synced with a workspace todo surface.
public struct MobileTodoItem: Codable, Equatable, Identifiable, Sendable {
    /// The maximum number of characters accepted for one item's normalized text.
    public static let maxTextLength = 500

    /// The Mac-owned stable item identifier.
    public let id: String
    /// The normalized item text.
    public let text: String
    /// The item's progress state.
    public let state: MobileTodoItemState
    /// Who created the item.
    public let origin: MobileTodoItemOrigin

    /// Creates a mobile checklist item.
    /// - Parameters:
    ///   - id: The Mac-owned stable item identifier.
    ///   - text: The normalized item text.
    ///   - state: The item's progress state.
    ///   - origin: Who created the item.
    public init(
        id: String,
        text: String,
        state: MobileTodoItemState,
        origin: MobileTodoItemOrigin
    ) {
        self.id = id
        self.text = text
        self.state = state
        self.origin = origin
    }
}
