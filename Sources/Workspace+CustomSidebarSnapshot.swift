import CmuxAgentChat
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
            remote: remote,
            agents: customSidebarAgentSnapshots(),
            groupId: groupId
        )
    }

    /// At most this many agent sessions are projected per workspace; the
    /// registry returns most-recent-first, so the cap drops the oldest.
    private static let customSidebarAgentLimit = 24

    /// Projects the agent-chat session registry's records hosted by this
    /// workspace's terminals into `workspaces[i].agents` snapshots.
    ///
    /// A record binds to this workspace when its hook-resolved surface id is
    /// one of this workspace's live terminal panels. Records without a
    /// surface binding fall back to their stored workspace id; records bound
    /// to a panel that lives elsewhere (or was closed) are excluded even when
    /// their stored workspace id matches, because that stored id goes stale
    /// across relaunches while the panel binding stays authoritative.
    private func customSidebarAgentSnapshots() -> [CustomSidebarAgentSnapshot] {
        guard let service = TerminalController.shared.agentChatTranscriptService else { return [] }
        let records = service.sessionRecords(workspaceID: nil)
        guard !records.isEmpty else { return [] }
        var surfaceIdByPanelId: [UUID: UUID] = [:]
        for paneId in bonsplitController.allPaneIds {
            for tab in bonsplitController.tabs(inPane: paneId) {
                guard let panelId = panelIdFromSurfaceId(tab.id) else { continue }
                surfaceIdByPanelId[panelId] = tab.id.uuid
            }
        }
        let workspaceIdString = id.uuidString
        var agents: [CustomSidebarAgentSnapshot] = []
        for record in records {
            let panelId = record.surfaceID.flatMap(UUID.init(uuidString:))
            if let panelId {
                guard surfaceIdByPanelId[panelId] != nil else { continue }
            } else {
                guard record.workspaceID == workspaceIdString else { continue }
            }
            let status: String
            let stateSince: Date?
            switch record.state {
            case .idle:
                status = "idle"
                stateSince = nil
            case .working(let since):
                status = "working"
                stateSince = since
            case .needsInput(let since):
                status = "needs_input"
                stateSince = since
            case .ended:
                status = "ended"
                stateSince = nil
            }
            agents.append(
                CustomSidebarAgentSnapshot(
                    sessionId: record.sessionID,
                    kind: record.agentKind.sourceName,
                    name: record.agentKind.displayName,
                    status: status,
                    stateSince: stateSince,
                    lastActivityAt: record.lastActivityAt,
                    title: record.title,
                    panelId: panelId,
                    surfaceId: panelId.flatMap { surfaceIdByPanelId[$0] },
                    workingDirectory: record.workingDirectory,
                    transcriptPath: record.transcriptPath,
                    pid: record.pid
                )
            )
            if agents.count >= Self.customSidebarAgentLimit { break }
        }
        return agents
    }

    private func customSidebarSurfaceSnapshots(focusedPanelId: UUID?) -> [CustomSidebarSurfaceSnapshot] {
        var surfaces: [CustomSidebarSurfaceSnapshot] = []
        for paneId in bonsplitController.allPaneIds {
            for tab in bonsplitController.tabs(inPane: paneId) {
                guard let panelId = panelIdFromSurfaceId(tab.id) else { continue }
                let git = reportedPanelGitBranch(panelId: panelId)
                surfaces.append(
                    CustomSidebarSurfaceSnapshot(
                        panelId: panelId,
                        surfaceId: tab.id.uuid,
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
