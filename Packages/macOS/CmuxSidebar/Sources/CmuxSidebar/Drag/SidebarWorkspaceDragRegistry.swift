public import Foundation

/// Process-wide registry of the workspace currently being dragged in any
/// window's sidebar.
///
/// One instance is constructed at the app composition root and injected into
/// every ``SidebarDragState`` (and read by the sidebar's drop delegate) so all
/// windows agree on the single in-flight drag without a shared global.
@MainActor
public final class SidebarWorkspaceDragRegistry: SidebarWorkspaceDragRegistering {
    private var activeWorkspaceId: UUID?

    /// Creates an empty registry with no drag in flight.
    public init() {}

    public var currentWorkspaceId: UUID? { activeWorkspaceId }

    public func begin(workspaceId: UUID) {
        activeWorkspaceId = workspaceId
    }

    public func end(workspaceId: UUID) {
        if activeWorkspaceId == workspaceId {
            activeWorkspaceId = nil
        }
    }
}
