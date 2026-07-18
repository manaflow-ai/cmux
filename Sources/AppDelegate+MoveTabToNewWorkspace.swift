import Foundation
import CmuxSettings

struct SurfaceNewWorkspaceMoveResult {
    let sourceWindowId: UUID
    let sourceWorkspaceId: UUID
    let destinationWindowId: UUID?
    let destinationWorkspaceId: UUID
    let surfaceId: UUID
    let paneId: UUID?
    let backendRequestId: UUID?

    init(
        sourceWindowId: UUID,
        sourceWorkspaceId: UUID,
        destinationWindowId: UUID?,
        destinationWorkspaceId: UUID,
        surfaceId: UUID,
        paneId: UUID?,
        backendRequestId: UUID? = nil
    ) {
        self.sourceWindowId = sourceWindowId
        self.sourceWorkspaceId = sourceWorkspaceId
        self.destinationWindowId = destinationWindowId
        self.destinationWorkspaceId = destinationWorkspaceId
        self.surfaceId = surfaceId
        self.paneId = paneId
        self.backendRequestId = backendRequestId
    }
}

@MainActor
extension AppDelegate {
    func canMoveSurfaceToNewWorkspace(panelId: UUID) -> Bool {
        guard let source = locateSurface(surfaceId: panelId),
              let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }),
              sourceWorkspace.panels[panelId] != nil else {
            return false
        }
        return sourceWorkspace.panels.count > 1
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
        placementOverride: WorkspacePlacement? = nil,
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
        placementOverride: WorkspacePlacement? = nil,
        insertionIndexOverride: Int? = nil
    ) -> SurfaceNewWorkspaceMoveResult? {
        guard let source = locateSurface(surfaceId: panelId),
              let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }),
              let sourcePanel = sourceWorkspace.panels[panelId],
              sourceWorkspace.panels.count > 1 else {
            return nil
        }
        let targetManager = destinationManager ?? source.tabManager
        let hasExplicitTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if !hasExplicitTitle {
            source.tabManager.flushPendingPanelTitleUpdatesForWorkspaceSnapshot()
        }
        let destinationTitle = titleForDetachedWorkspace(
            explicitTitle: title,
            workspace: sourceWorkspace,
            panelId: panelId,
            panel: sourcePanel
        )
        if let canonicalSurfaceID = sourceWorkspace.backendCanonicalSurfaceID(for: panelId),
           !sourceWorkspace.isApplyingCanonicalTopologyProjection {
            guard let mutationCoordinator = sourceWorkspace.terminalClientComposition
                .terminalBackendTopologyMutationCoordinator else {
                return nil
            }
            let destinationWorkspaceID = UUID()
            let requestedIndex = insertionIndexOverride.map {
                max(0, min($0, targetManager.tabs.count))
            }
            let canonicalIndex = requestedIndex.map { requestedIndex in
                targetManager.tabs.prefix(requestedIndex).filter { workspace in
                    workspace.panels.keys.contains(where: {
                        workspace.isBackendCanonicalPanel($0)
                    })
                }.count
            }
            var ownerReservation: TerminalBackendTopologyWorkspaceOwnerReservation?
            var surfaceReservation: TerminalBackendTopologyCanonicalSurfaceMoveReservation?
            do {
                guard let registry = terminalBackendTopologyProjectionRegistry else {
                    throw TerminalBackendTopologyProjectionError.projectionFailed(
                        "canonical workspace move has no projection registry"
                    )
                }
                ownerReservation = try registry.reserveWorkspaceOwner(
                    workspaceID: destinationWorkspaceID,
                    for: targetManager
                )
                surfaceReservation = source.tabManager === targetManager
                    ? nil
                    : try registry.reserveCanonicalSurfaceMove(
                            surfaceID: canonicalSurfaceID,
                            from: sourceWorkspace.id,
                            in: source.tabManager,
                            to: destinationWorkspaceID,
                            in: targetManager,
                            destinationPaneID: nil,
                            destinationIndex: nil
                        )
            } catch {
                if let ownerReservation {
                    terminalBackendTopologyProjectionRegistry?
                        .cancelWorkspaceOwnerReservation(ownerReservation)
                }
                mutationCoordinator.reportFailure(for: .createWorkspace)
                return nil
            }
            let activationIntent = focusIntentForNewWorkspaceMove(panel: sourcePanel)
            let submission = mutationCoordinator.requestMoveTabToNewWorkspace(
                canonicalSurfaceID,
                workspaceID: destinationWorkspaceID,
                name: destinationTitle,
                index: canonicalIndex,
                projectionOwnerID: ownerReservation?.presentationID
                    ?? targetManager.terminalBackendProjectionPresentationID,
                onProjected: { [weak self, weak targetManager] _ in
                    guard focus, let self, let targetManager,
                          targetManager.tabs.contains(where: {
                              $0.id == destinationWorkspaceID
                          }) else {
                        return
                    }
                    let destinationWindowId = focusWindow
                        ? self.windowId(for: targetManager)
                        : nil
                    if let destinationWindowId {
                        _ = self.focusMainWindow(windowId: destinationWindowId)
                    }
                    targetManager.focusTab(
                        destinationWorkspaceID,
                        surfaceId: panelId,
                        suppressFlash: true,
                        focusIntent: activationIntent
                    )
                    if let destinationWindowId {
                        self.reassertCrossWindowSurfaceMoveFocusIfNeeded(
                            destinationWindowId: destinationWindowId,
                            sourceWindowId: source.windowId,
                            destinationWorkspaceId: destinationWorkspaceID,
                            destinationPanelId: panelId,
                            destinationManager: targetManager
                        )
                    }
                },
                onFailure: { [weak registry = terminalBackendTopologyProjectionRegistry] in
                    if let surfaceReservation {
                        registry?.cancelCanonicalSurfaceMoveReservation(surfaceReservation)
                    }
                    if let ownerReservation {
                        registry?.cancelWorkspaceOwnerReservation(ownerReservation)
                    }
                }
            )
            return SurfaceNewWorkspaceMoveResult(
                sourceWindowId: source.windowId,
                sourceWorkspaceId: source.workspaceId,
                destinationWindowId: windowId(for: targetManager),
                destinationWorkspaceId: destinationWorkspaceID,
                surfaceId: panelId,
                paneId: nil,
                backendRequestId: submission.requestID
            )
        }
        let sourcePane = sourceWorkspace.paneId(forPanelId: panelId)
        let sourceIndex = sourceWorkspace.indexInPane(forPanelId: panelId)
        let activationIntent = focusIntentForNewWorkspaceMove(panel: sourcePanel)
        guard let detached = sourceWorkspace.detachSurface(panelId: panelId) else { return nil }

        guard let destinationWorkspace = targetManager.addWorkspace(
            fromDetachedSurface: detached,
            title: destinationTitle,
            select: false,
            placementOverride: placementOverride,
            insertionIndexOverride: insertionIndexOverride,
            focusIntent: activationIntent
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

        cleanupEmptySourceWorkspaceAfterSurfaceMove(
            sourceWorkspace: sourceWorkspace,
            sourceManager: source.tabManager,
            sourceWindowId: source.windowId
        )

        if focus {
            let destinationWindowId = focusWindow ? windowId(for: targetManager) : nil
            if let destinationWindowId {
                _ = focusMainWindow(windowId: destinationWindowId)
            }
            targetManager.focusTab(
                destinationWorkspace.id,
                surfaceId: panelId,
                suppressFlash: true,
                focusIntent: activationIntent
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

    private func focusIntentForNewWorkspaceMove(panel: any Panel) -> PanelFocusIntent {
        if panel is BrowserPanel {
            // Moving a browser tab into a standalone workspace should expose browser chrome,
            // even if web content was the last in-panel responder before the drag.
            return .browser(.addressBar)
        }
        return panel.preferredFocusIntentForActivation()
    }

    private func titleForDetachedWorkspace(
        explicitTitle: String?,
        workspace: Workspace,
        panelId: UUID,
        panel: any Panel
    ) -> String {
        let trimmedTitle = explicitTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTitle, !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        let fallbackTitle = workspace.panelTitle(panelId: panelId) ?? panel.displayTitle
        let trimmedFallbackTitle = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFallbackTitle.isEmpty {
            return trimmedFallbackTitle
        }

        return String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
    }
}
