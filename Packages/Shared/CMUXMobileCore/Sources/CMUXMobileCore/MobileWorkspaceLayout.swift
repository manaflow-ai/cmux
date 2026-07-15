/// The authoritative pane-and-tab topology for one Mac workspace.
public struct MobileWorkspaceLayout: Codable, Equatable, Identifiable, Sendable {
    /// The stable Mac workspace identifier.
    public var workspaceID: String
    /// The recursive split-pane tree.
    public var root: MobileWorkspaceLayoutNode
    /// The Mac's focused pane identifier, when a pane is focused.
    public var activePaneID: String?

    /// The workspace identifier used by `Identifiable` consumers.
    public var id: String { workspaceID }

    /// Creates an authoritative workspace layout snapshot.
    /// - Parameters:
    ///   - workspaceID: The stable Mac workspace identifier.
    ///   - root: The recursive split-pane tree.
    ///   - activePaneID: The focused pane identifier, when present.
    public init(
        workspaceID: String,
        root: MobileWorkspaceLayoutNode,
        activePaneID: String?
    ) {
        self.workspaceID = workspaceID
        self.root = root
        self.activePaneID = activePaneID
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case root
        case activePaneID = "active_pane_id"
    }
}
