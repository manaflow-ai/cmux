/// A Mac workspace's authoritative pane layout, independent of mobile state sync.
public struct DeviceWorkspaceLayoutSnapshot: Codable, Equatable, Sendable {
    /// The stable workspace ID on the owning Mac.
    public let workspaceID: String
    /// The ordered pane tree and divider proportions on the owning Mac.
    public let layout: DeviceWorkspaceLayoutNode

    /// Creates a snapshot for one Mac workspace.
    /// - Parameters:
    ///   - workspaceID: The owning Mac's stable workspace ID.
    ///   - layout: Its current pane tree.
    public init(workspaceID: String, layout: DeviceWorkspaceLayoutNode) {
        self.workspaceID = workspaceID
        self.layout = layout
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case layout
    }
}
