import CmuxSettings
import CmuxSidebar
import CmuxWorkspaces
import Foundation

/// App-target conformance routing the ``WorkspaceGroupJoinCoordinator`` seam
/// onto the live `TabManager`. The coordinator (in CmuxSidebar) speaks only in
/// `UUID`s and the placement value type, so the concrete `Workspace`/`TabManager`
/// god types never cross the package boundary.
extension TabManager: WorkspaceGroupJoining {
    func currentWorkspaceIds() -> [UUID] {
        tabs.map(\.id)
    }

    func groupContainsLiveGroup(_ groupId: UUID) -> Bool {
        workspaceGroups.contains { $0.id == groupId }
    }

    func containsWorkspace(_ workspaceId: UUID) -> Bool {
        tabs.contains { $0.id == workspaceId }
    }

    func addWorkspaceToGroup(
        workspaceId: UUID,
        groupId: UUID,
        placement: WorkspaceGroupNewPlacement,
        referenceWorkspaceId: UUID?
    ) {
        // Forward to the existing optional-placement method. Pass placement as
        // an explicit Optional so the call resolves to that overload instead of
        // recursing into this non-optional witness.
        let placementValue: WorkspaceGroupNewPlacement? = placement
        addWorkspaceToGroup(
            workspaceId: workspaceId,
            groupId: groupId,
            placement: placementValue,
            referenceWorkspaceId: referenceWorkspaceId
        )
    }

    func observeWorkspaceList(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> WorkspaceGroupJoinObservation {
        workspaces.observeTabs(onChange)
    }
}

/// Bridges the CmuxWorkspaces observation handle onto the sidebar seam's
/// cancellable contract. Both expose an idempotent `cancel()`.
extension WorkspacesObservation: WorkspaceGroupJoinObservation {}
