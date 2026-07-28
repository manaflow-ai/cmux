/// Workspace metadata visible to share participants.
public struct ShareSharedWorkspace: Codable, Equatable, Sendable {
    /// Wire workspace identifier.
    public var id: String

    /// Current host workspace title.
    public var title: String

    /// Creates workspace metadata.
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}
