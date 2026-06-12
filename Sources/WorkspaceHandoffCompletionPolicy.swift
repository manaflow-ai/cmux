import Foundation

/// Signals that can release a pending workspace handoff.
enum WorkspaceHandoffCompletionSignal {
    /// The selected workspace has committed its visible SwiftUI/AppKit state.
    case selectedWorkspaceVisible
    /// Focus has moved to the selected workspace before visibility committed.
    case selectedWorkspaceFocus
}

/// Decides when a workspace handoff can finish and the retiring workspace can
/// tear down its portal-backed views. A handoff starts when selection moves to a
/// new workspace while the previous workspace is still mounted as the retiring
/// workspace; `selectedWorkspaceReady` means the newly selected workspace has
/// enough rendered surface state for a visible transition. Completion is driven
/// by child visibility and focus signals rather than elapsed time.
enum WorkspaceHandoffCompletionPolicy {
    /// Returns whether an incoming completion signal should finish the active
    /// handoff. Visibility requires the selected workspace to be ready, focus is
    /// accepted for the selected workspace.
    static func shouldComplete(
        signal: WorkspaceHandoffCompletionSignal,
        selectedWorkspaceId: UUID?,
        signalWorkspaceId: UUID?,
        hasRetiringWorkspace: Bool,
        selectedWorkspaceReady: Bool
    ) -> Bool {
        guard hasRetiringWorkspace else { return false }

        switch signal {
        case .selectedWorkspaceVisible:
            return signalWorkspaceId == selectedWorkspaceId && selectedWorkspaceReady
        case .selectedWorkspaceFocus:
            return signalWorkspaceId == selectedWorkspaceId
        }
    }

    /// Returns whether handoff can complete immediately because the selected
    /// workspace is already in the visible-workspace set. This is a shortcut over
    /// `shouldComplete(...)` for state observed before a fresh signal arrives.
    static func shouldCompleteFromAlreadyVisibleSelectedWorkspace(
        selectedWorkspaceId: UUID?,
        visibleWorkspaceIds: Set<UUID>,
        hasRetiringWorkspace: Bool,
        selectedWorkspaceReady: Bool
    ) -> Bool {
        guard let selectedWorkspaceId,
              visibleWorkspaceIds.contains(selectedWorkspaceId) else {
            return false
        }
        return shouldComplete(
            signal: .selectedWorkspaceVisible,
            selectedWorkspaceId: selectedWorkspaceId,
            signalWorkspaceId: selectedWorkspaceId,
            hasRetiringWorkspace: hasRetiringWorkspace,
            selectedWorkspaceReady: selectedWorkspaceReady
        )
    }
}

enum WorkspaceVisibilityCommitState {
    static func updateVisibleWorkspaceIds(
        _ visibleWorkspaceIds: inout Set<UUID>,
        workspaceId: UUID,
        isVisible: Bool
    ) {
        if isVisible {
            visibleWorkspaceIds.insert(workspaceId)
        } else {
            visibleWorkspaceIds.remove(workspaceId)
        }
    }
}
