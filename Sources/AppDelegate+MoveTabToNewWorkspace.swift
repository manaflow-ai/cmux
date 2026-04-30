import Foundation

struct SurfaceNewWorkspaceMoveResult {
    let sourceWindowId: UUID
    let sourceWorkspaceId: UUID
    let destinationWindowId: UUID?
    let destinationWorkspaceId: UUID
    let surfaceId: UUID
    let paneId: UUID?
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

    @discardableResult
    func moveBonsplitTabToNewWorkspace(
        tabId: UUID,
        destinationManager: TabManager? = nil,
        title: String? = nil,
        focus: Bool = true,
        focusWindow: Bool = true,
        placementOverride: NewWorkspacePlacement? = nil
    ) -> SurfaceNewWorkspaceMoveResult? {
        guard let located = locateBonsplitSurface(tabId: tabId) else { return nil }
        return moveSurfaceToNewWorkspace(
            panelId: located.panelId,
            destinationManager: destinationManager,
            title: title,
            focus: focus,
            focusWindow: focusWindow,
            placementOverride: placementOverride
        )
    }

    @discardableResult
    func moveSurfaceToNewWorkspace(
        panelId: UUID,
        destinationManager: TabManager? = nil,
        title: String? = nil,
        focus: Bool = true,
        focusWindow: Bool = true,
        placementOverride: NewWorkspacePlacement? = nil
    ) -> SurfaceNewWorkspaceMoveResult? {
        guard let source = locateSurface(surfaceId: panelId),
              let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }),
              let sourcePanel = sourceWorkspace.panels[panelId],
              sourceWorkspace.panels.count > 1 else {
            return nil
        }

        let targetManager = destinationManager ?? source.tabManager
        let destinationTitle = titleForDetachedWorkspace(
            explicitTitle: title,
            workspace: sourceWorkspace,
            panelId: panelId,
            panel: sourcePanel
        )
        let destinationWorkspace = targetManager.addWorkspace(
            title: destinationTitle,
            select: focus,
            placementOverride: placementOverride,
            autoWelcomeIfNeeded: false
        )
        let bootstrapPanelIds = Set(destinationWorkspace.panels.keys)

        let moved = moveSurface(
            panelId: panelId,
            toWorkspace: destinationWorkspace.id,
            focus: focus,
            focusWindow: focusWindow
        )
        guard moved else {
            if targetManager.tabs.count > 1,
               targetManager.tabs.contains(where: { $0.id == destinationWorkspace.id }) {
                targetManager.closeWorkspace(destinationWorkspace)
            }
            return nil
        }

        for bootstrapPanelId in bootstrapPanelIds where bootstrapPanelId != panelId {
            if destinationWorkspace.panels[bootstrapPanelId] != nil {
                _ = destinationWorkspace.closePanel(bootstrapPanelId, force: true)
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
