/// The bounded todo payload attached to a synced todo surface.
public struct MobileTodoSnapshot: Codable, Equatable, Sendable {
    /// The maximum number of checklist items carried by one mobile snapshot.
    public static let maxItems = 50

    /// The effective status after applying any valid manual override.
    public let status: MobileTodoStatus
    /// Whether the workspace opted out of showing its status lane.
    public let statusHidden: Bool
    /// Checklist items in the Mac's storage order.
    public let items: [MobileTodoItem]

    /// Creates a todo snapshot.
    /// - Parameters:
    ///   - status: The effective workspace status.
    ///   - statusHidden: Whether status presentation is hidden.
    ///   - items: Checklist items in storage order.
    public init(status: MobileTodoStatus, statusHidden: Bool, items: [MobileTodoItem]) {
        self.status = status
        self.statusHidden = statusHidden
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case statusHidden = "status_hidden"
        case items
    }
}
