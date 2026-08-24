import Bonsplit
import CmuxFoundation
import CmuxSidebar
import Foundation

extension Workspace {
    /// Projects live workspace state into the custom-sidebar interpreter input snapshot.
    func customSidebarWorkspaceSnapshot(
        index: Int,
        selectedId: UUID?,
        unreadCount: Int
    ) -> CustomSidebarWorkspaceSnapshot {
        let focusedPanelId = focusedPanelId
        let firstBranch = sidebarGitBranchesInDisplayOrder().first
        let progress = self.progress.map {
            CustomSidebarWorkspaceSnapshot.Progress(value: $0.value, label: $0.label)
        }
        let remote = remoteDisplayTarget.map { target in
            CustomSidebarWorkspaceSnapshot.Remote(
                target: target,
                stateRawValue: remoteConnectionState.rawValue,
                isConnected: remoteConnectionState == .connected
            )
        }
        let panes = customSidebarPaneSnapshots(focusedPanelId: focusedPanelId)
        return CustomSidebarWorkspaceSnapshot(
            id: id,
            title: customTitle ?? title,
            isSelected: id == selectedId,
            isPinned: isPinned,
            index: index,
            directory: presentedCurrentDirectory ?? "",
            listeningPorts: listeningPorts,
            unreadCount: unreadCount,
            surfaces: panes.flatMap(\.surfaces),
            panes: panes,
            surfaceCount: bonsplitController.allPaneIds.reduce(0) {
                $0 + bonsplitController.tabs(inPane: $1).count
            },
            customDescription: customDescription,
            customColor: customColor,
            gitBranch: firstBranch?.branch,
            gitIsDirty: firstBranch?.isDirty ?? false,
            pullRequestValues: customSidebarPullRequestValues(),
            progress: progress,
            latestConversationMessage: latestConversationMessage,
            latestSubmittedMessage: latestSubmittedMessage,
            latestSubmittedAt: latestSubmittedAt,
            remote: remote
        )
    }

    private func customSidebarPaneSnapshots(
        focusedPanelId: UUID?
    ) -> [CustomSidebarWorkspaceSnapshot.Pane] {
        let spatialIds = spatiallyOrderedPaneIds
        let paneIds = spatialIds.isEmpty ? bonsplitController.allPaneIds.map(\.id) : spatialIds
        return paneIds.enumerated().map { index, paneUUID in
            let paneId = PaneID(id: paneUUID)
            let selectedTabId = bonsplitController.selectedTabId(inPane: paneId)
            let surfaces: [CustomSidebarSurfaceSnapshot] =
                bonsplitController
                    .tabs(inPane: paneId)
                    .compactMap { tab -> CustomSidebarSurfaceSnapshot? in
                        guard let panelId = panelIdFromSurfaceId(tab.id) else { return nil }
                        let git = reportedPanelGitBranch(panelId: panelId)
                        return CustomSidebarSurfaceSnapshot(
                            panelId: panelId,
                            title: tab.title,
                            isFocused: panelId == focusedPanelId,
                            isSelected: tab.id == selectedTabId,
                            isPinned: pinnedPanelIds.contains(panelId),
                            directory: reportedPanelDirectory(panelId: panelId),
                            gitBranch: git?.branch,
                            gitIsDirty: git?.isDirty ?? false,
                            listeningPorts: surfaceListeningPorts[panelId] ?? [],
                            agentStatus: AgentStatus.resolve(
                                lifecycles: agentLifecycleStatesByPanelId[panelId] ?? [:]
                            )
                        )
                    }
            return CustomSidebarWorkspaceSnapshot.Pane(
                id: paneUUID,
                index: index,
                isFocused: bonsplitController.focusedPaneId == paneId,
                surfaces: surfaces
            )
        }
    }
}
