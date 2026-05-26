import Foundation

enum WorkspaceHandoffCompletionSignal {
    case selectedWorkspaceVisible
    case selectedWorkspaceFocus
    case timeout
}

enum WorkspaceHandoffCompletionPolicy {
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
        case .timeout:
            return true
        }
    }

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
