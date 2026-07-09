import Bonsplit
import CmuxWorkspaces
import Foundation

/// `AppDelegate`'s conformance to ``PaneSurfaceMoveHosting``: the irreducible
/// live-state operations ``PaneSurfaceMoveCoordinator`` drives when it moves a
/// surface between panes, workspaces, and windows.
///
/// The coordinator owns the move *decision* (destination-pane resolution, path
/// selection, bonsplit-tab → panel-id indirection, move-target projection); this
/// file owns every step that reaches the live `Workspace`/`TabManager`/bonsplit
/// state, the `NSWindow` focus, and the cross-workspace detach-scoped tail whose
/// detached-surface transfer token cannot leave the executable target. Each
/// witness mirrors the corresponding step of the legacy `AppDelegate.moveSurface`
/// body one-for-one, in its legacy order (including the `#if DEBUG cmuxDebugLog`
/// traces whose ordering relative to the live steps is observable), so the move
/// stays byte-faithful.
@MainActor
extension AppDelegate: PaneSurfaceMoveHosting {
    func resolveSourceLocation(surfaceId: UUID) -> PaneSurfaceMoveSourceLocation? {
        guard let located = windowRegistry.locateSurface(surfaceId: surfaceId) else { return nil }
        return PaneSurfaceMoveSourceLocation(
            windowId: located.windowId,
            workspaceId: located.workspaceId
        )
    }

    func resolveBonsplitLocation(
        tabId: UUID
    ) -> (location: PaneSurfaceMoveSourceLocation, panelId: UUID)? {
        guard let located = locateBonsplitSurface(tabId: tabId) else { return nil }
        return (
            PaneSurfaceMoveSourceLocation(windowId: located.windowId, workspaceId: located.workspaceId),
            located.panelId
        )
    }

    func workspaceExists(_ workspaceId: UUID) -> Bool {
        guard let manager = tabManagerFor(tabId: workspaceId) else { return false }
        return manager.tabs.contains(where: { $0.id == workspaceId })
    }

    func windowId(forWorkspace workspaceId: UUID) -> UUID? {
        guard let manager = tabManagerFor(tabId: workspaceId) else { return nil }
        return windowId(for: manager)
    }

    func resolveTargetPane(inWorkspace workspaceId: UUID, requested targetPane: PaneID?) -> PaneID? {
        guard let manager = tabManagerFor(tabId: workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == workspaceId }) else {
            return nil
        }
        return targetPane.flatMap { pane in
            workspace.bonsplitController.allPaneIds.first(where: { $0 == pane })
        } ?? workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first
    }

    func splitSameWorkspace(
        workspaceId: UUID,
        panelId: UUID,
        targetPane: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        focus: Bool
    ) -> Bool {
        guard let manager = tabManagerFor(tabId: workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == workspaceId }),
              let sourceTabId = workspace.surfaceIdFromPanelId(panelId),
              workspace.bonsplitController.splitPane(
                targetPane,
                orientation: orientation,
                movingTab: sourceTabId,
                insertFirst: insertFirst
              ) != nil else {
            return false
        }
        if focus {
            manager.focusTab(workspaceId, surfaceId: panelId, suppressFlash: true)
        }
        return true
    }

    func moveSameWorkspace(
        workspaceId: UUID,
        panelId: UUID,
        targetPane: PaneID,
        atIndex index: Int?,
        focus: Bool
    ) -> Bool {
        guard let manager = tabManagerFor(tabId: workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == workspaceId }) else {
            return false
        }
        return workspace.moveSurface(
            panelId: panelId,
            toPane: targetPane,
            atIndex: index,
            focus: focus
        )
    }

    func performCrossWorkspaceMove(
        panelId: UUID,
        sourceWorkspaceId: UUID,
        sourceWindowId: UUID,
        plan: PaneSurfaceMoveCrossWorkspacePlan
    ) -> Bool {
        guard let sourceManager = tabManagerFor(tabId: sourceWorkspaceId),
              let sourceWorkspace = sourceManager.tabs.first(where: { $0.id == sourceWorkspaceId }),
              let destinationManager = tabManagerFor(tabId: plan.destinationWorkspaceId),
              let destinationWorkspace = destinationManager.tabs.first(where: { $0.id == plan.destinationWorkspaceId }) else {
            return false
        }

        let sourcePane = sourceWorkspace.paneId(forPanelId: panelId)
        let sourceIndex = sourceWorkspace.indexInPane(forPanelId: panelId)

        guard let detached = sourceWorkspace.detachSurface(panelId: panelId) else {
            return false
        }

        guard destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: plan.targetPane,
            atIndex: plan.targetIndex,
            focus: plan.focus
        ) != nil else {
            rollbackDetachedSurface(
                detached,
                to: sourceWorkspace,
                sourcePane: sourcePane,
                sourceIndex: sourceIndex,
                focus: plan.focus
            )
            return false
        }

        if let splitTarget = plan.splitTarget {
            guard let movedTabId = destinationWorkspace.surfaceIdFromPanelId(panelId),
                  destinationWorkspace.bonsplitController.splitPane(
                    plan.targetPane,
                    orientation: splitTarget.orientation,
                    movingTab: movedTabId,
                    insertFirst: splitTarget.insertFirst
                  ) != nil else {
                if let detachedFromDestination = destinationWorkspace.detachSurface(panelId: panelId) {
                    rollbackDetachedSurface(
                        detachedFromDestination,
                        to: sourceWorkspace,
                        sourcePane: sourcePane,
                        sourceIndex: sourceIndex,
                        focus: plan.focus
                    )
                }
                return false
            }
        }

        cleanupEmptySourceWorkspaceAfterSurfaceMove(
            sourceWorkspace: sourceWorkspace,
            sourceManager: sourceManager,
            sourceWindowId: sourceWindowId
        )

        if plan.focus {
            let destinationWindowId = plan.destinationWindowId
            if let destinationWindowId {
                _ = environment.mainWindowRouter.focusMainWindow(windowId: destinationWindowId)
            }
            destinationManager.focusTab(plan.destinationWorkspaceId, surfaceId: panelId, suppressFlash: true)
            if let destinationWindowId {
                reassertCrossWindowSurfaceMoveFocusIfNeeded(
                    destinationWindowId: destinationWindowId,
                    sourceWindowId: sourceWindowId,
                    destinationWorkspaceId: plan.destinationWorkspaceId,
                    destinationPanelId: panelId,
                    destinationManager: destinationManager
                )
            }
        }

        return true
    }
}
