/// Protocol seam for workspace restore metadata inspected by remote reconnect policy.
public protocol WorkspaceSessionRemoteRestoreSnapshot: Sendable {
    /// Panel restore metadata type.
    associatedtype PanelSnapshot: WorkspaceSessionRemoteRestorePanelSnapshot

    /// Panel snapshots restored with the workspace.
    var panels: [PanelSnapshot] { get }
}
