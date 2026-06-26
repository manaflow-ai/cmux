public import Foundation

/// Workspace + surface pair used to mirror the store's per-surface unread set.
public struct SidebarSurfaceUnreadKey: Hashable {
    /// Identifier of the owning workspace (legacy `tabId`).
    public var workspaceId: UUID
    /// Identifier of the surface, or `nil` for the workspace-level entry.
    public var surfaceId: UUID?

    /// Creates a workspace/surface unread key.
    public init(workspaceId: UUID, surfaceId: UUID?) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
    }
}
