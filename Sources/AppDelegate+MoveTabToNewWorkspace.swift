import Foundation
import CmuxSettings
import CmuxWindowing

@MainActor
extension AppDelegate {
    func canMoveSurfaceToNewWorkspace(panelId: UUID) -> Bool {
        environment.mainWindowRouter.canMoveSurfaceToNewWorkspace(panelId: panelId)
    }

    func canMoveBonsplitTabToNewWorkspace(tabId: UUID) -> Bool {
        environment.mainWindowRouter.canMoveBonsplitTabToNewWorkspace(tabId: tabId)
    }

    func canMoveBonsplitTab(tabId: UUID, toWorkspace targetWorkspaceId: UUID) -> Bool {
        environment.mainWindowRouter.canMoveBonsplitTab(
            tabId: tabId,
            toWorkspace: targetWorkspaceId
        )
    }

    func workspaceMoveTargets(forSurface panelId: UUID) -> [WorkspaceMoveTarget] {
        environment.mainWindowRouter.workspaceMoveTargets(forSurface: panelId)
    }

    func workspaceMoveTargets(forBonsplitTab tabId: UUID) -> [WorkspaceMoveTarget] {
        environment.mainWindowRouter.workspaceMoveTargets(forBonsplitTab: tabId)
    }

    @discardableResult
    func moveBonsplitTabToNewWorkspace(
        tabId: UUID,
        destinationManager: TabManager? = nil,
        title: String? = nil,
        focus: Bool = true,
        focusWindow: Bool = true,
        placementOverride: WorkspacePlacement? = nil,
        insertionIndexOverride: Int? = nil
    ) -> SurfaceNewWorkspaceMoveResult? {
        environment.mainWindowRouter.moveBonsplitTabToNewWorkspace(
            tabId: tabId,
            destinationManager: destinationManager,
            title: title,
            focus: focus,
            focusWindow: focusWindow,
            placementOverride: placementOverride,
            insertionIndexOverride: insertionIndexOverride
        )
    }

    @discardableResult
    func moveSurfaceToNewWorkspace(
        panelId: UUID,
        destinationManager: TabManager? = nil,
        title: String? = nil,
        focus: Bool = true,
        focusWindow: Bool = true,
        placementOverride: WorkspacePlacement? = nil,
        insertionIndexOverride: Int? = nil
    ) -> SurfaceNewWorkspaceMoveResult? {
        environment.mainWindowRouter.moveSurfaceToNewWorkspace(
            panelId: panelId,
            destinationManager: destinationManager,
            title: title,
            focus: focus,
            focusWindow: focusWindow,
            placementOverride: placementOverride,
            insertionIndexOverride: insertionIndexOverride
        )
    }

    func cleanupEmptySourceWorkspaceAfterSurfaceMove(
        sourceWorkspace: Workspace,
        sourceManager: TabManager,
        sourceWindowId: UUID
    ) {
        environment.mainWindowRouter.cleanupEmptySourceWorkspaceAfterSurfaceMove(
            sourceWorkspace: sourceWorkspace,
            sourceManager: sourceManager,
            sourceWindowId: sourceWindowId
        )
    }
}
