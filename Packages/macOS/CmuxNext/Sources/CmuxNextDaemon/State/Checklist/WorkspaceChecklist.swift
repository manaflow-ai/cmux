/// One workspace's checklist (`WorkspaceChecklist`, `workspace-checklist-v1`): its items in list
/// order. The daemon publishes the whole list on every change, as the `workspace_checklist`
/// state resource, so a mirror replaces its copy.
public struct WorkspaceChecklist: Sendable, Hashable, Decodable {
    /// The workspace's public id (`ws_…`).
    public var workspaceID: ResourceID
    /// The items, in list order (at most 50).
    public var items: [WorkspaceChecklistItem]

    enum CodingKeys: String, CodingKey {
        case items
        case workspaceID = "workspace_id"
    }

    /// Creates a checklist.
    /// - Parameters:
    ///   - workspaceID: The workspace's public id.
    ///   - items: The items, in list order.
    public init(workspaceID: ResourceID, items: [WorkspaceChecklistItem] = []) {
        self.workspaceID = workspaceID
        self.items = items
    }
}
