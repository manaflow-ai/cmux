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
    private weak var autoscrollOwner: (any SidebarWorkspaceDragAutoscrollOwning)?

    /// Creates an empty registry with no drag in flight.
    public init() {}

    public var currentWorkspaceId: UUID? { activeWorkspaceId }

    public func begin(workspaceId: UUID) {
        relinquishAutoscrollOwner()
        activeWorkspaceId = workspaceId
    }

    public func end(workspaceId: UUID) {
        if activeWorkspaceId == workspaceId {
            activeWorkspaceId = nil
            relinquishAutoscrollOwner()
        }
    }

    /// Makes `owner` the exclusive autoscroll destination for the active drag.
    public func claimAutoscroll(owner: any SidebarWorkspaceDragAutoscrollOwning) {
        guard activeWorkspaceId != nil else {
            owner.relinquishWorkspaceDragAutoscroll()
            return
        }
        guard autoscrollOwner !== owner else { return }
        relinquishAutoscrollOwner()
        autoscrollOwner = owner
    }

    /// Releases the current autoscroll destination when it matches `owner`.
    public func releaseAutoscroll(owner: any SidebarWorkspaceDragAutoscrollOwning) {
        guard autoscrollOwner === owner else { return }
        autoscrollOwner = nil
    }

    private func relinquishAutoscrollOwner() {
        let previousOwner = autoscrollOwner
        autoscrollOwner = nil
        previousOwner?.relinquishWorkspaceDragAutoscroll()
    }
}
