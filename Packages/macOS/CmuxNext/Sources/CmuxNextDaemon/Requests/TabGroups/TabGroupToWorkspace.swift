import Foundation

/// Drops a whole group on the sidebar: a new workspace holding the group,
/// optionally in a sidebar group at a section index. Tear-off = this + open
/// the returned workspace in a new window.
public struct MoveTabGroupToNewWorkspaceRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "move-tab-group-to-new-workspace"
    public static let requiredCapability: String? = DaemonCapabilities.shared.tabGroups
    public var group: TabGroupID
    /// Sidebar (workspace) group for the new workspace.
    public var workspaceGroup: WorkspaceGroupID?
    public var index: Int?
    public var transaction: ClientTransactionID?
    public init(group: TabGroupID, workspaceGroup: WorkspaceGroupID? = nil, index: Int? = nil, transaction: ClientTransactionID? = nil) {
        self.group = group
        self.workspaceGroup = workspaceGroup
        self.index = index
        self.transaction = transaction
    }
}
