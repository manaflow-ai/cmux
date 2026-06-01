import Foundation

struct SurfaceNewWorkspaceMoveResult {
    let sourceWindowId: UUID
    let sourceWorkspaceId: UUID
    let destinationWindowId: UUID?
    let destinationWorkspaceId: UUID
    let surfaceId: UUID
    let paneId: UUID?
}

struct SurfaceNewWorkspaceCreationRequest {
    let detached: Workspace.DetachedSurfaceTransfer
    let title: String
    let focusIntent: PanelFocusIntent
}

@MainActor
extension AppDelegate {
    func canMoveSurfaceToNewWorkspace(panelId: UUID) -> Bool {
        guard let source = locateSurface(surfaceId: panelId),
              let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }),
              sourceWorkspace.panels[panelId] != nil else {
            return false
        }
        return Self.canMoveSurfaceToNewWorkspace(
            sourceContainsPanel: true,
            sourcePanelCount: sourceWorkspace.panels.count
        )
    }

    func canMoveBonsplitTabToNewWorkspace(tabId: UUID) -> Bool {
        guard let located = locateBonsplitSurface(tabId: tabId) else { return false }
        return canMoveSurfaceToNewWorkspace(panelId: located.panelId)
    }

    func canMoveBonsplitTab(tabId: UUID, toWorkspace targetWorkspaceId: UUID) -> Bool {
        guard let located = locateBonsplitSurface(tabId: tabId),
              let sourceWorkspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
              sourceWorkspace.panels[located.panelId] != nil,
              let destinationManager = tabManagerFor(tabId: targetWorkspaceId),
              destinationManager.tabs.contains(where: { $0.id == targetWorkspaceId }) else {
            return false
        }
        return true
    }

    func workspaceMoveTargets(forSurface panelId: UUID) -> [WorkspaceMoveTarget] {
        guard let source = locateSurface(surfaceId: panelId) else { return [] }
        return workspaceMoveTargets(
            excludingWorkspaceId: source.workspaceId,
            referenceWindowId: source.windowId
        )
    }

    func workspaceMoveTargets(forBonsplitTab tabId: UUID) -> [WorkspaceMoveTarget] {
        guard let located = locateBonsplitSurface(tabId: tabId) else { return [] }
        return workspaceMoveTargets(
            excludingWorkspaceId: located.workspaceId,
            referenceWindowId: located.windowId
        )
    }

    @discardableResult
    func moveBonsplitTabToNewWorkspace(
        tabId: UUID,
        destinationManager: TabManager? = nil,
        title: String? = nil,
        focus: Bool = true,
        focusWindow: Bool = true,
        placementOverride: NewWorkspacePlacement? = nil,
        insertionIndexOverride: Int? = nil
    ) -> SurfaceNewWorkspaceMoveResult? {
        guard let located = locateBonsplitSurface(tabId: tabId) else { return nil }
        return moveSurfaceToNewWorkspace(
            panelId: located.panelId,
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
        placementOverride: NewWorkspacePlacement? = nil,
        insertionIndexOverride: Int? = nil
    ) -> SurfaceNewWorkspaceMoveResult? {
        guard let source = locateSurface(surfaceId: panelId),
              let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }),
              let sourcePanel = sourceWorkspace.panels[panelId],
              sourceWorkspace.panels.count > 1 else {
            return nil
        }

        let targetManager = destinationManager ?? source.tabManager
        let sourcePanelTitle = sourceWorkspace.panelTitle(panelId: panelId)
        let sourcePane = sourceWorkspace.paneId(forPanelId: panelId)
        let sourceIndex = sourceWorkspace.indexInPane(forPanelId: panelId)
        guard let detached = sourceWorkspace.detachSurface(panelId: panelId) else { return nil }
        let creationRequest = Self.surfaceNewWorkspaceCreationRequest(
            detached: detached,
            explicitTitle: title,
            panelTitle: sourcePanelTitle,
            panel: sourcePanel
        )

        guard let destinationWorkspace = targetManager.addWorkspace(
            fromDetachedSurface: creationRequest.detached,
            title: creationRequest.title,
            select: false,
            placementOverride: placementOverride,
            insertionIndexOverride: insertionIndexOverride,
            focusIntent: creationRequest.focusIntent
        ) else {
            rollbackDetachedSurface(
                detached,
                to: sourceWorkspace,
                sourcePane: sourcePane,
                sourceIndex: sourceIndex,
                focus: focus
            )
            return nil
        }

        let postAttachActions = Self.surfaceMovePostAttachActions(
            focus: focus,
            sourceWorkspaceIsEmpty: sourceWorkspace.panels.isEmpty,
            sourceWorkspaceIsRegistered: source.tabManager.tabs.contains { $0.id == sourceWorkspace.id },
            sourceWorkspaceCount: source.tabManager.tabs.count
        )
        for action in postAttachActions {
            switch action {
            case .focusDestination:
                let destinationWindowId = focusWindow ? windowId(for: targetManager) : nil
                if let destinationWindowId {
                    _ = focusMainWindow(windowId: destinationWindowId)
                }
                targetManager.focusTab(
                    destinationWorkspace.id,
                    surfaceId: panelId,
                    suppressFlash: true,
                    focusIntent: creationRequest.focusIntent
                )
                if let destinationWindowId {
                    reassertCrossWindowSurfaceMoveFocusIfNeeded(
                        destinationWindowId: destinationWindowId,
                        sourceWindowId: source.windowId,
                        destinationWorkspaceId: destinationWorkspace.id,
                        destinationPanelId: panelId,
                        destinationManager: targetManager
                    )
                }
            case .cleanupEmptySourceWorkspace(let cleanupAction):
                performEmptySourceWorkspaceCleanupAfterSurfaceMove(
                    cleanupAction,
                    sourceWorkspace: sourceWorkspace,
                    sourceManager: source.tabManager,
                    sourceWindowId: source.windowId
                )
            }
        }

        return SurfaceNewWorkspaceMoveResult(
            sourceWindowId: source.windowId,
            sourceWorkspaceId: source.workspaceId,
            destinationWindowId: windowId(for: targetManager),
            destinationWorkspaceId: destinationWorkspace.id,
            surfaceId: panelId,
            paneId: destinationWorkspace.paneId(forPanelId: panelId)?.id
        )
    }

    static func canMoveSurfaceToNewWorkspace(
        sourceContainsPanel: Bool,
        sourcePanelCount: Int
    ) -> Bool {
        sourceContainsPanel && sourcePanelCount > 1
    }

    static func surfaceNewWorkspaceCreationRequest(
        detached: Workspace.DetachedSurfaceTransfer,
        explicitTitle: String?,
        panelTitle: String?,
        panel: any Panel
    ) -> SurfaceNewWorkspaceCreationRequest {
        SurfaceNewWorkspaceCreationRequest(
            detached: detached,
            title: titleForDetachedWorkspace(
                explicitTitle: explicitTitle,
                panelTitle: panelTitle,
                panelDisplayTitle: panel.displayTitle
            ),
            focusIntent: focusIntentForNewWorkspaceMove(
                panelType: panel.panelType,
                preferredFocusIntent: panel.preferredFocusIntentForActivation()
            )
        )
    }

    static func focusIntentForNewWorkspaceMove(
        panelType: PanelType,
        preferredFocusIntent: PanelFocusIntent
    ) -> PanelFocusIntent {
        if panelType == .browser {
            // Moving a browser tab into a standalone workspace should expose browser chrome,
            // even if web content was the last in-panel responder before the drag.
            return .browser(.addressBar)
        }
        return preferredFocusIntent
    }

    private func focusIntentForNewWorkspaceMove(panel: any Panel) -> PanelFocusIntent {
        Self.focusIntentForNewWorkspaceMove(
            panelType: panel.panelType,
            preferredFocusIntent: panel.preferredFocusIntentForActivation()
        )
    }

    static func titleForDetachedWorkspace(
        explicitTitle: String?,
        panelTitle: String?,
        panelDisplayTitle: String
    ) -> String {
        let trimmedTitle = explicitTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTitle, !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        let fallbackTitle = panelTitle ?? panelDisplayTitle
        let trimmedFallbackTitle = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFallbackTitle.isEmpty {
            return trimmedFallbackTitle
        }

        return String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
    }
}
