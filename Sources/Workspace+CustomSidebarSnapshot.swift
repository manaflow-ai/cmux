import Bonsplit
import CmuxSidebar
import Foundation

extension Workspace {
    /// Projects live workspace state into the custom-sidebar interpreter input snapshot.
    ///
    /// The bonsplit tree structure is read once per build: `orderedPanelIds`
    /// feeds the git-branch and pull-request projections, and the pane/tab
    /// listing feeds both the surface snapshots and the surface count. The
    /// callers memoize the resulting snapshot (see
    /// `CustomSidebarDataContextStore`), so this whole function runs only
    /// after a coalesced invalidation, never on the 1 Hz clock tick.
    func customSidebarWorkspaceSnapshot(
        index: Int,
        selectedId: UUID?,
        unreadCount: Int
    ) -> CustomSidebarWorkspaceSnapshot {
        let orderedPanelIds = sidebarOrderedPanelIds()
        let paneTabs = bonsplitController.allPaneIds.map { bonsplitController.tabs(inPane: $0) }
        let focusedPanelId = focusedPanelId
        let firstBranch = sidebarGitBranchesInDisplayOrder(orderedPanelIds: orderedPanelIds).first
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
            surfaces: customSidebarSurfaceSnapshots(paneTabs: paneTabs, focusedPanelId: focusedPanelId),
            surfaceCount: paneTabs.reduce(0) { $0 + $1.count },
            customDescription: customDescription,
            customColor: customColor,
            gitBranch: firstBranch?.branch,
            gitIsDirty: firstBranch?.isDirty ?? false,
            pullRequestValues: customSidebarPullRequestValues(orderedPanelIds: orderedPanelIds),
            progress: progress,
            latestConversationMessage: latestConversationMessage,
            latestSubmittedMessage: latestSubmittedMessage,
            latestSubmittedAt: latestSubmittedAt,
            remote: remote
        )
    }

    private func customSidebarSurfaceSnapshots(
        paneTabs: [[Bonsplit.Tab]],
        focusedPanelId: UUID?
    ) -> [CustomSidebarSurfaceSnapshot] {
        var surfaces: [CustomSidebarSurfaceSnapshot] = []
        for tabs in paneTabs {
            for tab in tabs {
                guard let panelId = panelIdFromSurfaceId(tab.id) else { continue }
                let git = reportedPanelGitBranch(panelId: panelId)
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
