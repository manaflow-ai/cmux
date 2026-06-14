import Bonsplit
import CmuxBrowser
import CmuxWorkspaceCore
import Foundation

extension Workspace {
    func installInitialBrowserPanel() -> TabID? {
        let browserPanel = BrowserPanel(
            workspaceId: id,
            profileID: resolvedNewBrowserProfileID()
        )
        configureBrowserPanel(browserPanel)
        panels[browserPanel.id] = browserPanel
        panelTitles[browserPanel.id] = browserPanel.displayTitle
        _ = browserPanel.requestAddressBarFocus(selectionIntent: .selectAll)

        guard let tabId = bonsplitController.createTab(
            title: browserPanel.displayTitle,
            icon: browserPanel.displayIcon,
            kind: SurfaceKind.browser,
            isDirty: browserPanel.isDirty,
            isLoading: browserPanel.isLoading,
            isAudioMuted: browserPanel.isMuted,
            isPinned: false
        ) else {
            return nil
        }
        surfaceIdToPanelId[tabId] = browserPanel.id
        installBrowserPanelSubscription(browserPanel)
        return tabId
    }

    func installInitialGuiModePanel(
        initialDirectory: String,
        workingDirectory: String?
    ) -> TabID? {
        let guiPanel = AgentSessionPanel(
            workspaceId: id,
            rendererKind: .guiMode,
            initialProviderID: .codex,
            workingDirectory: workingDirectory
        )
        panels[guiPanel.id] = guiPanel
        panelTitles[guiPanel.id] = guiPanel.displayTitle
        if !initialDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panelDirectories[guiPanel.id] = initialDirectory
        }

        guard let tabId = bonsplitController.createTab(
            title: guiPanel.displayTitle,
            icon: guiPanel.displayIcon,
            kind: SurfaceKind.agentSession,
            isDirty: guiPanel.isDirty,
            isLoading: false,
            isPinned: false
        ) else {
            return nil
        }
        surfaceIdToPanelId[tabId] = guiPanel.id
        installAgentSessionPanelSubscription(guiPanel)
        return tabId
    }
}
