public import Foundation

/// Read/write seam for the process-wide identity of the workspace currently
/// being sidebar-dragged in any window.
///
/// This is intentionally the compatibility surface for package clients that
/// only need to mirror a workspace identity. Native/session-aware behavior lives
/// in ``SidebarWorkspaceDragSessionRegistering`` so those clients are not forced
/// to implement lifecycle machinery they cannot own.
@MainActor
public protocol SidebarWorkspaceDragRegistering: AnyObject {
    /// The workspace currently being sidebar-dragged anywhere in the process,
    /// or `nil` when no sidebar drag is in flight.
    var currentWorkspaceId: UUID? { get }

    /// Record the start of a sidebar drag. Called by the originating window.
    func begin(workspaceId: UUID)

    /// Clear the active drag, but only if `workspaceId` still matches the
    /// in-flight drag, so a stale clear from a superseded drag is a no-op.
    func end(workspaceId: UUID)
}
