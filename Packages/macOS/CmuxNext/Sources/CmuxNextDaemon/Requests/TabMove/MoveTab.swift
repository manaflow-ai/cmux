import Foundation

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
