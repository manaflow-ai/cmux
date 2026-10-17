import CmuxAgentChat
import CmuxSidebar
import Foundation

@MainActor
extension Workspace {
    /// Projects live workspace state into the custom-sidebar interpreter input snapshot.
    func customSidebarWorkspaceSnapshot(
        index: Int,
        selectedId: UUID?,
        unreadCount: Int
    ) -> CustomSidebarWorkspaceSnapshot {
        let focusedPanelId = focusedPanelId
        let displayTitle = customTitle ?? title
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
            title: displayTitle,
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
            groupId: groupId,
            taskStatus: effectiveTaskStatus.rawValue,
            emoji: Self.customSidebarLeadingEmoji(in: displayTitle)
        )
    }

    /// Returns the first grapheme when a workspace display title starts with
    /// an emoji. The custom-sidebar context keeps the full title and exposes
    /// this optional projection so a sidebar can render the emoji separately.
    private static func customSidebarLeadingEmoji(in title: String) -> String? {
        guard let first = title.first,
              first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) else {
            return nil
        }
        return String(first)
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
            let lifecycle = Self.customSidebarAgentLifecycle(
                sessionID: record.sessionID,
                currentSessionID: panelId.flatMap {
                    service.registry.liveSessionSnapshot(surfaceID: $0.uuidString)?.sessionID
                },
                sessionAliases: [record.hookStoreLookupSessionID],
                state: record.state,
                agentSource: record.agentKind.sourceName,
                panelLifecycles: panelId.flatMap { agentLifecycleStatesByPanelId[$0] } ?? [:],
                lifecycleSessionIDs: panelId.flatMap { agentLifecycleSessionIDsByPanelId[$0] } ?? [:]
            )
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
                    pid: record.pid,
                    children: record.children.map { child in
                        CustomSidebarAgentChildSnapshot(
                            id: child.id,
                            label: child.label,
                            isRunning: child.isRunning,
                            startedAt: child.startedAt,
                            endedAt: child.endedAt
                        )
                    },
                    lifecycle: lifecycle
                )
            )
            if agents.count >= Self.customSidebarAgentLimit { break }
        }
        return agents
    }

    /// Returns the custom-sidebar wire value for the lifecycle recorded on an
    /// agent's hosting panel.
    nonisolated static func customSidebarAgentLifecycle(
        sessionID: String,
        currentSessionID: String?,
        sessionAliases: [String] = [],
        state: ChatAgentState,
        agentSource: String,
        panelLifecycles: [String: AgentHibernationLifecycleState] = [:],
        lifecycleSessionIDs: [String: String] = [:]
    ) -> String? {
        // A lifecycle belongs to the currently bound session. Avoid exposing
        // a newer session's panel state on an ended or superseded record.
        if case .ended = state { return nil }
        guard currentSessionID == sessionID else { return nil }

        let key = FeedCoordinator.lifecycleStatusKey(forSource: agentSource)
        guard let lifecycleSessionID = lifecycleSessionIDs[key],
              lifecycleSessionID == sessionID || sessionAliases.contains(lifecycleSessionID) else {
            return nil
        }
        guard let lifecycle = panelLifecycles[key] else { return nil }
        switch lifecycle {
        case .unknown: return "unknown"
        case .running: return "running"
        case .backgroundWorkPending: return "background_work_pending"
        case .needsInput: return "needs_input"
        case .idle: return "idle"
        }
    }

    private func customSidebarSurfaceSnapshots(focusedPanelId: UUID?) -> [CustomSidebarSurfaceSnapshot] {
        var surfaces: [CustomSidebarSurfaceSnapshot] = []
        for paneId in bonsplitController.allPaneIds {
            for tab in bonsplitController.tabs(inPane: paneId) {
                guard let panelId = panelIdFromSurfaceId(tab.id) else { continue }
                // Keep tab identity stable, but expose only IDs accepted by surface.*.
                // A mirror without a projection stays visible without a focus target.
                let focusSurfaceId = isRemoteTmuxControlContainer(panelId)
                    ? activeRemoteTmuxControlSurfaceProjection(containerPanelID: panelId)?.surfaceID
                    : panelId
                let git = reportedPanelGitBranch(panelId: panelId)
                let prompt = panelPrompts[panelId]
                surfaces.append(
                    CustomSidebarSurfaceSnapshot(
                        panelId: panelId,
                        surfaceId: focusSurfaceId,
                        title: tab.title,
                        isFocused: panelId == focusedPanelId,
                        isPinned: pinnedPanelIds.contains(panelId),
                        directory: reportedPanelDirectory(panelId: panelId),
                        gitBranch: git?.branch,
                        gitIsDirty: git?.isDirty ?? false,
                        listeningPorts: surfaceListeningPorts[panelId] ?? [],
                        latestSubmittedMessage: prompt?.message,
                        latestSubmittedAt: prompt?.submittedAt,
                        hasUnreadNotification: hasUnreadNotification(panelId: panelId)
                    )
                )
            }
        }
        return surfaces
    }
}
