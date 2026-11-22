import Foundation

/// Reorder within a strip or move into any pane (across screens and
/// workspaces). Pinned tabs stay first (`tab-metadata-v1`).
public struct MoveTabRequest: DaemonRequest {
    public typealias Response = TabMoveResult
    public static let command = "move-tab"
    public var surface: SurfaceID
    public var pane: PaneID
    public var index: Int
    /// Echoed in `tab-changed` (`tab-drag-v1`); 1-128 printable ASCII.
    public var transaction: ClientTransactionID?
    public init(surface: SurfaceID, pane: PaneID, index: Int, transaction: ClientTransactionID? = nil) {
        self.surface = surface
        self.pane = pane
        self.index = index
        self.transaction = transaction
    }
}

/// Move into an existing workspace's active pane, or a new workspace when
/// `workspace` is nil (`tab-workspace-move-v1`).
public struct MoveTabToWorkspaceRequest: DaemonRequest {
    public typealias Response = TabMoveResult
    public static let command = "move-tab-to-workspace"
    public var surface: SurfaceID
    public var workspace: WorkspaceHandle?
    public var transaction: ClientTransactionID?
    public init(surface: SurfaceID, workspace: WorkspaceHandle?, transaction: ClientTransactionID? = nil) {
        self.surface = surface
        self.workspace = workspace
        self.transaction = transaction
    }
}

/// Drop on the sidebar: new workspace holding the tab, optionally in a group
/// at a final section index. Tear-off = this + open the workspace in a new window.
public struct MoveTabToNewWorkspaceRequest: DaemonRequest {
    public typealias Response = TabMoveResult
    public static let command = "move-tab-to-new-workspace"
    public static let requiredCapability: String? = DaemonCapabilities.shared.tabDrag
    public var surface: SurfaceID
    public var group: WorkspaceGroupID?
    public var index: Int?
    /// The new workspace's name (`tab-workspace-name-v1`); nil keeps the
    /// daemon's default. Sent only to a daemon that advertises it.
    public var name: String?
    public var transaction: ClientTransactionID?
    public init(surface: SurfaceID, group: WorkspaceGroupID? = nil, index: Int? = nil, name: String? = nil,
                transaction: ClientTransactionID? = nil) {
        self.surface = surface
        self.group = group
        self.index = index
        self.name = name
        self.transaction = transaction
    }
}
