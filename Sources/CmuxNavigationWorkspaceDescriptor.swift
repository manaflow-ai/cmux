import Foundation

/// One workspace, described by both of its identities plus its child targets.
struct CmuxNavigationWorkspaceDescriptor: Equatable {
    /// Session-scoped workspace identifier (`Workspace.id`).
    let workspaceId: UUID
    /// Restart-stable workspace identifier (`Workspace.stableId`).
    let stableId: UUID
    /// Session-scoped bonsplit pane identifiers. Panes are layout nodes with no
    /// persisted identity, so pane routes resolve by exact match only.
    let paneIds: [UUID]
    let surfaces: [CmuxNavigationSurfaceDescriptor]
}
