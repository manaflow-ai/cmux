import CmuxControlSocket
import CmuxCore
import Foundation

/// Workspace snapshots are built at the live main-actor ownership boundary.
extension TerminalController {
    // MARK: - Snapshots

    /// Builds the Sendable summary of one workspace (the legacy
    /// `v2WorkspaceSummaryPayload` data, minus the index/selected/ref minting the
    /// coordinator now owns), bridging the app-typed `remoteStatusPayload()`.
    private func controlWorkspaceSummary(_ workspace: Workspace) -> ControlWorkspaceSummary {
        ControlWorkspaceSummary(
            id: workspace.id, title: workspace.title, customTitle: workspace.customTitle,
            customDescription: workspace.customDescription,
            isPinned: workspace.isPinned,
            listeningPorts: workspace.listeningPorts,
            remoteStatus: JSONValue(foundationObject: workspace.remoteStatusPayload()) ?? .object([:]),
            currentDirectory: workspace.presentedCurrentDirectory ?? "",
            customColor: workspace.customColor,
            latestConversationMessage: workspace.latestConversationMessage,
            latestSubmittedMessage: workspace.latestSubmittedMessage,
            latestSubmittedAt: workspace.latestSubmittedAt.map(CmuxEventBus.isoTimestamp)
        )
    }

    // MARK: - List / current

    func controlWorkspaceList(routing: ControlRoutingSelectors) -> ControlWorkspaceListResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        if let owner = routing.remoteRelayOwnerWorkspaceID {
            // Resolve only the authenticated owner. Never materialize another
            // workspace's summary or the owner's daemon/connection payload.
            guard let workspace = tabManager.tabs.first(where: { $0.id == owner }),
                  remoteRelayTargetIsCurrent(routing: routing, workspace: workspace) else {
                return .relayOwnerUnavailable
            }
            return .relayWorkspace(id: owner, title: workspace.title)
        }
        let selectedId = tabManager.selectedTabId
        var selectedIndex: Int?
        let summaries = tabManager.tabs.enumerated().map { index, ws -> ControlWorkspaceSummary in
            if ws.id == selectedId {
                selectedIndex = index
            }
            return controlWorkspaceSummary(ws)
        }
        let windowId = AppDelegate.shared?.windowId(for: tabManager)
        return .resolved(windowID: windowId, workspaces: summaries, selectedIndex: selectedIndex)
    }

    func controlWorkspaceCurrent(routing: ControlRoutingSelectors) -> ControlWorkspaceCurrentResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        // A relay request carries the authenticated workspace explicitly.  Do
        // not answer with whichever workspace happens to be focused in that
        // window, because it can be a local workspace in the same manager.
        guard let workspaceId = routing.workspaceID ?? tabManager.selectedTabId else {
            return .noWorkspaceSelected
        }
        // Legacy: a selectedTabId pointing at a workspace missing from `tabs`
        // still answered .ok with "workspace": null.
        let workspace = tabManager.tabs.first(where: { $0.id == workspaceId })
        let index = tabManager.tabs.firstIndex(where: { $0.id == workspaceId })
        let windowId = AppDelegate.shared?.windowId(for: tabManager)
        return .resolved(
            windowID: windowId,
            workspaceID: workspaceId,
            index: index,
            summary: workspace.map { controlWorkspaceSummary($0) }
        )
    }
}
