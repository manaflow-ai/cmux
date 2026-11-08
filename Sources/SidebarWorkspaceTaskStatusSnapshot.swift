import CmuxWorkspaces
import Foundation

/// Status-menu inputs belong to the same cached workspace projection as its
/// visible row. Selection, hover and catalog updates must not re-walk panes.
struct SidebarWorkspaceTaskStatusSnapshot: Equatable {
    var inferred: WorkspaceTaskStatus = .todo
    var activeOverride: WorkspaceTaskStatus?
    var isHidden = false

    @MainActor
    static func capture(workspace: Workspace, orderedPanelIds: [UUID]) -> Self {
        let inferred = WorkspaceTaskStatus.inferred(from: workspace.taskStatusSignals(orderedPanelIds: orderedPanelIds))
        let override = workspace.todoState.statusOverride
        let resolution = WorkspaceTaskStatusOverride.effectiveStatus(override: override, inferred: inferred)
        return Self(
            inferred: inferred,
            activeOverride: resolution.shouldClearOverride ? nil : override?.status,
            isHidden: workspace.todoState.statusHidden
        )
    }
}
