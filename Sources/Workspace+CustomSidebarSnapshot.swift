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
        return CustomSidebarWorkspaceSnapshot(
            id: id,
            title: customTitle ?? title,
            isSelected: id == selectedId,
            isPinned: isPinned,
            index: index,
            directory: presentedCurrentDirectory ?? "",
            listeningPorts: listeningPorts,
            unreadCount: unreadCount,
            surfaces: customSidebarSurfaceSnapshots(focusedPanelId: focusedPanelId),
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

    private func customSidebarSurfaceSnapshots(focusedPanelId: UUID?) -> [CustomSidebarSurfaceSnapshot] {
        var surfaces: [CustomSidebarSurfaceSnapshot] = []
        for paneId in bonsplitController.allPaneIds {
            for tab in bonsplitController.tabs(inPane: paneId) {
                guard let panelId = panelIdFromSurfaceId(tab.id) else { continue }
                let git = panelGitBranches[panelId]
                surfaces.append(
                    CustomSidebarSurfaceSnapshot(
                        panelId: panelId,
                        title: tab.title,
                        isFocused: panelId == focusedPanelId,
                        isPinned: pinnedPanelIds.contains(panelId),
                        directory: reportedPanelDirectory(panelId: panelId),
                        gitBranch: git?.branch,
                        gitIsDirty: git?.isDirty ?? false,
                        listeningPorts: surfaceListeningPorts[panelId] ?? []
                    )
                )
            }
        }
        return surfaces
    }
}
