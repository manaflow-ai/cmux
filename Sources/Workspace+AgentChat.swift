import AppKit
import Bonsplit
import CmuxWorkspaces

extension Workspace {
    func createInitialAgentSessionPanel(workingDirectory: String?) -> TabID? {
        let trimmedDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = trimmedDirectory?.isEmpty == false ? trimmedDirectory : nil
        let panel = AgentSessionPanel(
            workspaceId: id,
            rendererKind: .react,
            initialProviderID: .codex,
            workingDirectory: directory
        )
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle
        if let directory {
            panelDirectories[panel.id] = directory
        }

        let tabId = bonsplitController.createTab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.agentSession.rawValue,
            isDirty: panel.isDirty,
            isLoading: false,
            isPinned: false
        )
        if let tabId {
            bindSurface(tabId, toPanelId: panel.id)
        }
        installAgentSessionPanelSubscription(panel)
        return tabId
    }

    func performSurfaceTabBarNewAgentChatAction(presentingWindow: NSWindow?) {
        guard let owningTabManager else { return }
        _ = AppDelegate.shared?.executeConfiguredCmuxAction(
            id: CmuxSurfaceTabBarBuiltInAction.newAgentChat.configID,
            tabManager: owningTabManager,
            preferredWindow: presentingWindow
        )
    }
}
