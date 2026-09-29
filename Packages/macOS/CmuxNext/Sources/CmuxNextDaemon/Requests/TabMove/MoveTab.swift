import Foundation

/// Reorder within a strip or move into another pane's strip.
public struct MoveTabRequest: DaemonRequest {
    public typealias Response = TabMoveResult
    public static let command = "move-tab"
    public var surface: SurfaceID
    public var pane: PaneID
    public var index: Int
    public var clientTransactionID: ClientTransactionID?
    public init(surface: SurfaceID, pane: PaneID, index: Int, clientTransactionID: ClientTransactionID? = nil) {
        self.surface = surface
        self.pane = pane
        self.index = index
        self.clientTransactionID = clientTransactionID
    }
}

/// Move into an existing workspace (its active pane), or a new one when
/// `workspace` is nil (`tab-workspace-move-v1`, implemented today).
public struct MoveTabToWorkspaceRequest: DaemonRequest {
    public typealias Response = TabMoveResult
    public static let command = "move-tab-to-workspace"
    public var surface: SurfaceID
    public var workspace: WorkspaceHandle?
    public var clientTransactionID: ClientTransactionID?
    public init(surface: SurfaceID, workspace: WorkspaceHandle?, clientTransactionID: ClientTransactionID? = nil) {
        self.surface = surface
        self.workspace = workspace
        self.clientTransactionID = clientTransactionID
    }
}
