import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Session snapshot capture
extension Workspace {
    func sessionSnapshot(
        includeScrollback: Bool,
        restorableAgentIndex: RestorableAgentSessionIndex? = nil,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil
    ) -> SessionWorkspaceSnapshot {
        let tree = bonsplitController.treeSnapshot()
        let rawLayout = sessionLayoutSnapshot(from: tree)
        if let surfaceResumeBindingIndex {
            reconcileSurfaceResumeBindings(using: surfaceResumeBindingIndex)
        }

        let orderedPanelIds = sidebarOrderedPanelIds()
        var seen: Set<UUID> = []
        var allPanelIds: [UUID] = []
        for panelId in orderedPanelIds where seen.insert(panelId).inserted {
            allPanelIds.append(panelId)
        }
        for panelId in panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) where seen.insert(panelId).inserted {
            allPanelIds.append(panelId)
        }

        let panelSnapshots = allPanelIds
            .prefix(SessionPersistencePolicy.maxPanelsPerWorkspace)
            .compactMap { panelId in
                sessionPanelSnapshot(
                    panelId: panelId,
                    includeScrollback: includeScrollback,
                    restorableAgent: restorableAgentIndex?.snapshot(workspaceId: id, panelId: panelId),
                    resumeBinding: effectiveSurfaceResumeBinding(
                        panelId: panelId,
                        surfaceResumeBindingIndex: surfaceResumeBindingIndex
                    )
                )
            }
        let persistedPanelIds = Set(panelSnapshots.map(\.id))
        let layout = prunedSessionLayoutSnapshot(rawLayout, keeping: persistedPanelIds) ?? .pane(
            SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)
        )

        let statusSnapshots = statusEntries.values
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { entry in
                SessionStatusEntrySnapshot(
                    key: entry.key,
                    value: entry.value,
                    icon: entry.icon,
                    color: entry.color,
                    timestamp: entry.timestamp.timeIntervalSince1970
                )
            }
        let logSnapshots = logEntries.map { entry in
            SessionLogEntrySnapshot(
                message: entry.message,
                level: entry.level.rawValue,
                source: entry.source,
                timestamp: entry.timestamp.timeIntervalSince1970
            )
        }

        let progressSnapshot = progress.map { progress in
            SessionProgressSnapshot(value: progress.value, label: progress.label)
        }
        let gitBranchSnapshot = gitBranch.map { branch in
            SessionGitBranchSnapshot(branch: branch.branch, isDirty: branch.isDirty)
        }
        let notificationStore = AppDelegate.shared?.notificationStore
        let isWorkspaceManuallyUnread = notificationStore?.hasManualUnread(forTabId: id) ?? false
        let hasWorkspaceUnreadIndicator =
            (notificationStore?.hasUnreadNotification(forTabId: id, surfaceId: nil) ?? false) ||
            (notificationStore?.hasRestoredUnreadIndicator(forTabId: id) ?? false)
        let workspaceNotificationSnapshots = notificationSnapshots(surfaceId: nil)

        return SessionWorkspaceSnapshot(
            workspaceId: id,
            processTitle: processTitle,
            customTitle: customTitle,
            customDescription: customDescription,
            customColor: customColor,
            isPinned: isPinned,
            groupId: groupId,
            isManuallyUnread: isWorkspaceManuallyUnread,
            hasUnreadIndicator: hasWorkspaceUnreadIndicator,
            notifications: workspaceNotificationSnapshots.isEmpty ? nil : workspaceNotificationSnapshots,
            currentDirectory: currentDirectory,
            focusedPanelId: focusedPanelId,
            layout: layout,
            panels: panelSnapshots,
            statusEntries: statusSnapshots,
            logEntries: logSnapshots,
            progress: progressSnapshot,
            gitBranch: gitBranchSnapshot,
            remote: remoteConfiguration?.sessionSnapshot()
        )
    }

    @discardableResult
    func restoreSessionSnapshot(_ snapshot: SessionWorkspaceSnapshot) -> [UUID: UUID] {
        let previousSuppressClosedPanelHistory = suppressClosedPanelHistory
        suppressClosedPanelHistory = true
        defer { suppressClosedPanelHistory = previousSuppressClosedPanelHistory }

        restoredTerminalScrollbackByPanelId.removeAll(keepingCapacity: false)
#if DEBUG
        debugSessionSnapshotScrollbackFallbackPanelIds.removeAll(keepingCapacity: false)
        debugSessionSnapshotSyntheticScrollbackByPanelId.removeAll(keepingCapacity: false)
#endif
        restoredAgentSnapshotsByPanelId.removeAll(keepingCapacity: false)
        restoredAgentResumeStatesByPanelId.removeAll(keepingCapacity: false)
        invalidatedRestoredAgentFingerprintsByPanelId.removeAll(keepingCapacity: false)
        surfaceResumeBindingsByPanelId.removeAll(keepingCapacity: false)
        restoredGuardedWorkingDirectoriesByPanelId.removeAll(keepingCapacity: false)

        let restoredRemoteConfiguration = snapshot.remote?.workspaceConfiguration(
            localSocketPath: TerminalController.shared.currentSocketPathForRemoteRestore()
        )
        if let restoredRemoteConfiguration {
            let shouldAutoConnect = Self.shouldAutoConnectRestoredRemote(
                foregroundAuthToken: restoredRemoteConfiguration.foregroundAuthToken,
                snapshot: snapshot
            )
            configureRemoteConnection(
                restoredRemoteConfiguration,
                autoConnect: shouldAutoConnect
            )
        } else {
            disconnectRemoteConnection(clearConfiguration: true)
        }

        let normalizedCurrentDirectory = snapshot.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedCurrentDirectory.isEmpty {
            currentDirectory = normalizedCurrentDirectory
        }

        let panelSnapshotsById = Dictionary(uniqueKeysWithValues: snapshot.panels.map { ($0.id, $0) })
        let leafEntries: [SessionPaneRestoreEntry] = {
            let previousValue = suppressRemoteTerminalStartupForSessionRestoreScaffold
            suppressRemoteTerminalStartupForSessionRestoreScaffold = true
            defer { suppressRemoteTerminalStartupForSessionRestoreScaffold = previousValue }
            return restoreSessionLayout(snapshot.layout)
        }()
        var oldToNewPanelIds: [UUID: UUID] = [:]

        for entry in leafEntries {
            restorePane(
                entry.paneId,
                snapshot: entry.snapshot,
                panelSnapshotsById: panelSnapshotsById,
                snapshotWorkspaceId: snapshot.workspaceId,
                oldToNewPanelIds: &oldToNewPanelIds
            )
        }

        pruneSurfaceMetadata(validSurfaceIds: Set(panels.keys))
        applySessionDividerPositions(snapshotNode: snapshot.layout, liveNode: bonsplitController.treeSnapshot())

        applyProcessTitle(snapshot.processTitle)
        setCustomTitle(snapshot.customTitle)
        setCustomDescription(snapshot.customDescription)
        setCustomColor(snapshot.customColor)
        isPinned = snapshot.isPinned
        groupId = snapshot.groupId

        // Status entries and agent PIDs are ephemeral runtime state tied to running
        // processes (e.g. claude_code "Running"). Don't restore them across app
        // restarts because the processes that set them are gone.
        statusEntries.removeAll()
        agentPIDs.removeAll()
        agentPIDPanelIdsByKey.removeAll()
        agentPIDKeysByPanelId.removeAll()
        clearAllAgentLifecycleStates()
        agentListeningPorts.removeAll()
        logEntries = snapshot.logEntries.map { entry in
            SidebarLogEntry(
                message: entry.message,
                level: SidebarLogLevel(rawValue: entry.level) ?? .info,
                source: entry.source,
                timestamp: Date(timeIntervalSince1970: entry.timestamp)
            )
        }
        progress = snapshot.progress.map { SidebarProgressState(value: $0.value, label: $0.label) }
        gitBranch = snapshot.gitBranch.map { SidebarGitBranchState(branch: $0.branch, isDirty: $0.isDirty) }

        recomputeListeningPorts()

        if let focusedOldPanelId = snapshot.focusedPanelId,
           let focusedNewPanelId = oldToNewPanelIds[focusedOldPanelId],
           panels[focusedNewPanelId] != nil {
            focusPanel(focusedNewPanelId)
        } else if let fallbackFocusedPanelId = focusedPanelId, panels[fallbackFocusedPanelId] != nil {
            focusPanel(fallbackFocusedPanelId)
        } else {
            scheduleFocusReconcile()
        }
        let isWorkspaceManuallyUnread = snapshot.isManuallyUnread == true
        restoreWorkspaceManualUnread(isWorkspaceManuallyUnread)
        let restoredNotifications = restoredSessionNotifications(
            from: snapshot,
            oldToNewPanelIds: oldToNewPanelIds
        )
        let hasUnreadWorkspaceNotification = snapshot.notifications?.contains { !$0.isRead } == true
        if snapshot.hasUnreadIndicator == true, !hasUnreadWorkspaceNotification {
            AppDelegate.shared?.notificationStore?.restoreUnreadIndicator(forTabId: id)
        } else {
            AppDelegate.shared?.notificationStore?.clearRestoredUnreadIndicator(forTabId: id)
        }
        AppDelegate.shared?.notificationStore?.restoreSessionNotifications(restoredNotifications, forTabId: id)
        syncUnreadBadgeStateForAllPanels()
        return oldToNewPanelIds
    }

    private func sessionLayoutSnapshot(from node: ExternalTreeNode) -> SessionWorkspaceLayoutSnapshot {
        switch node {
        case .pane(let pane):
            let panelIds = sessionPanelIDs(for: pane)
            let selectedPanelId = pane.selectedTabId.flatMap(sessionPanelID(forExternalTabIDString:))
            return .pane(
                SessionPaneLayoutSnapshot(
                    panelIds: panelIds,
                    selectedPanelId: selectedPanelId
                )
            )
        case .split(let split):
            return .split(
                SessionSplitLayoutSnapshot(
                    orientation: split.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                    dividerPosition: split.dividerPosition,
                    first: sessionLayoutSnapshot(from: split.first),
                    second: sessionLayoutSnapshot(from: split.second)
                )
            )
        }
    }

    private func prunedSessionLayoutSnapshot(
        _ node: SessionWorkspaceLayoutSnapshot,
        keeping panelIdsToKeep: Set<UUID>
    ) -> SessionWorkspaceLayoutSnapshot? {
        switch node {
        case .pane(let pane):
            let panelIds = pane.panelIds.filter { panelIdsToKeep.contains($0) }
            guard !panelIds.isEmpty else { return nil }
            let selectedPanelId = pane.selectedPanelId.flatMap {
                panelIdsToKeep.contains($0) ? $0 : nil
            } ?? panelIds.first
            return .pane(SessionPaneLayoutSnapshot(panelIds: panelIds, selectedPanelId: selectedPanelId))
        case .split(let split):
            let first = prunedSessionLayoutSnapshot(split.first, keeping: panelIdsToKeep)
            let second = prunedSessionLayoutSnapshot(split.second, keeping: panelIdsToKeep)
            switch (first, second) {
            case (.some(let first), .some(let second)):
                return .split(
                    SessionSplitLayoutSnapshot(
                        orientation: split.orientation,
                        dividerPosition: split.dividerPosition,
                        first: first,
                        second: second
                    )
                )
            case (.some(let first), .none):
                return first
            case (.none, .some(let second)):
                return second
            case (.none, .none):
                return nil
            }
        }
    }

    private func sessionPanelIDs(for pane: ExternalPaneNode) -> [UUID] {
        var panelIds: [UUID] = []
        var seen = Set<UUID>()
        for tab in pane.tabs {
            guard let panelId = sessionPanelID(forExternalTabIDString: tab.id) else { continue }
            if seen.insert(panelId).inserted {
                panelIds.append(panelId)
            }
        }
        return panelIds
    }

    private func sessionPanelID(forExternalTabIDString tabIDString: String) -> UUID? {
        guard let tabUUID = UUID(uuidString: tabIDString) else { return nil }
        for (surfaceId, panelId) in surfaceIdToPanelId {
            guard let surfaceUUID = sessionSurfaceUUID(for: surfaceId) else { continue }
            if surfaceUUID == tabUUID {
                return panelId
            }
        }
        return nil
    }

    private func sessionSurfaceUUID(for surfaceId: TabID) -> UUID? {
        struct EncodedSurfaceID: Decodable {
            let id: UUID
        }

        guard let data = try? JSONEncoder().encode(surfaceId),
              let decoded = try? JSONDecoder().decode(EncodedSurfaceID.self, from: data) else {
            return nil
        }
        return decoded.id
    }

    func sessionPanelSnapshot(
        panelId: UUID,
        includeScrollback: Bool,
        restorableAgent: SessionRestorableAgentSnapshot?,
        resumeBinding: SurfaceResumeBindingSnapshot?
    ) -> SessionPanelSnapshot? {
        guard let panel = panels[panelId] else { return nil }

        if let restorableAgent {
            let fingerprint = TabManager.restorableAgentSnapshotFingerprint(restorableAgent)
            if invalidatedRestoredAgentFingerprintsByPanelId[panelId] == fingerprint {
                clearRestoredAgentSnapshot(panelId: panelId)
            } else {
                restoredAgentSnapshotsByPanelId[panelId] = restorableAgent
                if restoredAgentResumeStatesByPanelId[panelId] == nil {
                    restoredAgentResumeStatesByPanelId[panelId] = restoredAgentResumeStateForAcceptedSnapshot(
                        panelId: panelId
                    )
                }
                invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
            }
        }
        let hibernationState = (panel as? TerminalPanel)?.agentHibernationState
        let effectiveRestorableAgent = hibernationState?.agent ?? restoredAgentSnapshotsByPanelId[panelId]

        let panelTitle = panelTitle(panelId: panelId)
        let customTitle = panelCustomTitles[panelId]
        let directory: String? = {
            if let directory = panelDirectories[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !directory.isEmpty {
                return directory
            }
            if let agentPanel = panel as? AgentSessionPanel,
               let agentDirectory = agentPanel.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
               !agentDirectory.isEmpty {
                return agentDirectory
            }
            if let restorableDirectory = effectiveRestorableAgent?.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
               !restorableDirectory.isEmpty {
                return restorableDirectory
            }
            if let terminalPanel = panel as? TerminalPanel,
               let requestedDirectory = terminalPanel.requestedWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
               !requestedDirectory.isEmpty {
                return requestedDirectory
            }
            return nil
        }()
        let isPinned = pinnedPanelIds.contains(panelId)
        let isManuallyUnread = manualUnreadPanelIds.contains(panelId)
        let panelNotificationSnapshots = notificationSnapshots(surfaceId: panelId)
        let panelHasUnreadNotification = hasUnreadNotification(panelId: panelId)
        let hasUnreadIndicator =
            restoredUnreadPanelIds.contains(panelId) ||
            hasVisibleNotificationIndicator(panelId: panelId)
        let restoredUnreadContributesToWorkspace: Bool? = {
            if let restoredIndicator = restoredUnreadPanelIndicators[panelId] {
                return restoredIndicator.contributesToWorkspaceUnread
            }
            if hasUnreadIndicator && !panelHasUnreadNotification {
                return false
            }
            return nil
        }()
        let branchSnapshot = panelGitBranches[panelId].map {
            SessionGitBranchSnapshot(branch: $0.branch, isDirty: $0.isDirty)
        }
        let listeningPorts: [Int]
        if remoteDetectedSurfaceIds.contains(panelId) || isRemoteTerminalSurface(panelId) {
            listeningPorts = []
        } else {
            listeningPorts = (surfaceListeningPorts[panelId] ?? []).sorted()
        }
        let ttyName = surfaceTTYNames[panelId]

        let terminalSnapshot: SessionTerminalPanelSnapshot?
        let browserSnapshot: SessionBrowserPanelSnapshot?
        let markdownSnapshot: SessionMarkdownPanelSnapshot?
        let filePreviewSnapshot: SessionFilePreviewPanelSnapshot?
        let rightSidebarToolSnapshot: SessionRightSidebarToolPanelSnapshot?
        let agentSessionSnapshot: SessionAgentSessionPanelSnapshot?
        let projectSnapshot: SessionProjectPanelSnapshot?
        switch panel.panelType {
        case .terminal:
            guard let terminalPanel = panel as? TerminalPanel else { return nil }
            let restorableTmuxStartCommand = effectiveRestorableAgent == nil
                ? Self.restorableTmuxStartCommand(terminalPanel.surface.debugTmuxStartCommand())
                : nil
            let agentWasRunning: Bool? = {
                guard effectiveRestorableAgent != nil else { return nil }
                switch panelShellActivityStates[panelId] {
                case .some(.commandRunning):
                    return true
                case .some(.promptIdle):
                    return false
                case .some(.unknown), .none:
                    return nil
                }
            }()
            let resumeStartupInput = Self.surfaceResumeStartupInput(
                resumeBinding,
                autoResumeAgentSessions: AgentSessionAutoResumeSettings.isEnabled() && (agentWasRunning ?? true),
                promptForApproval: false
            )
            let shouldPersistScrollback = Self.shouldPersistSessionScrollback(
                shellActivityState: panelShellActivityStates[panelId],
                fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose()
            ) && Self.shouldReplaySessionScrollback(
                restorableAgent: effectiveRestorableAgent,
                tmuxStartCommand: restorableTmuxStartCommand,
                hasResumeStartupWork: resumeStartupInput != nil
            )
#if DEBUG
            let allowDebugFallbackScrollback = debugSessionSnapshotScrollbackFallbackPanelIds.contains(panelId)
#else
            let allowDebugFallbackScrollback = false
#endif
            let capturedScrollback = includeScrollback && shouldPersistScrollback && hibernationState == nil
                ? TerminalController.shared.readTerminalTextForSnapshot(
                    terminalPanel: terminalPanel,
                    includeScrollback: true,
                    lineLimit: SessionPersistencePolicy.maxScrollbackLinesPerTerminal
                )
                : nil
            let hasRestoredScrollbackFallback = restoredTerminalScrollbackByPanelId[panelId] != nil
            let resolvedScrollback = terminalSnapshotScrollback(
                panelId: panelId,
                capturedScrollback: capturedScrollback,
                includeScrollback: includeScrollback,
                allowFallbackScrollback: shouldPersistScrollback || allowDebugFallbackScrollback || hasRestoredScrollbackFallback
            )
            terminalSnapshot = SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                scrollback: resolvedScrollback,
                agent: effectiveRestorableAgent,
                tmuxStartCommand: restorableTmuxStartCommand,
                hibernation: hibernationState.map {
                    SessionAgentHibernationSnapshot(
                        hibernatedAt: $0.hibernatedAt.timeIntervalSince1970,
                        lastActivityAt: $0.lastActivityAt.timeIntervalSince1970
                    )
                },
                resumeBinding: resumeBinding,
                textBoxDraft: terminalPanel.sessionTextBoxDraftSnapshot(),
                isRemoteTerminal: activeRemoteTerminalSurfaceIds.contains(panelId),
                remotePTYSessionID: remotePTYSessionIDForSnapshot(panelId: panelId),
                wasAgentRunning: agentWasRunning
            )
            browserSnapshot = nil
            markdownSnapshot = nil
            filePreviewSnapshot = nil
            rightSidebarToolSnapshot = nil
            agentSessionSnapshot = nil
            projectSnapshot = nil
        case .browser:
            guard let browserPanel = panel as? BrowserPanel else { return nil }
            guard browserPanel.shouldPersistSessionSnapshot() else { return nil }
            terminalSnapshot = nil
            let historySnapshot = browserPanel.sessionNavigationHistorySnapshot()
            let diffViewerComponents = browserPanel.diffViewerSessionComponents()
            browserSnapshot = SessionBrowserPanelSnapshot(
                urlString: browserPanel.preferredURLStringForSessionSnapshot(),
                profileID: browserPanel.profileID,
                shouldRenderWebView: browserPanel.shouldRenderWebViewForSessionSnapshot(),
                pageZoom: Double(browserPanel.currentPageZoomFactor()),
                developerToolsVisible: browserPanel.isDeveloperToolsVisible(),
                isMuted: browserPanel.isMuted,
                omnibarVisible: browserPanel.isOmnibarVisible,
                backHistoryURLStrings: historySnapshot.backHistoryURLStrings,
                forwardHistoryURLStrings: historySnapshot.forwardHistoryURLStrings,
                transparentBackground: browserPanel.sessionSnapshotTransparentBackground,
                diffViewerToken: diffViewerComponents?.token,
                diffViewerRequestPath: diffViewerComponents?.requestPath
            )
            markdownSnapshot = nil
            filePreviewSnapshot = nil
            rightSidebarToolSnapshot = nil
            agentSessionSnapshot = nil
            projectSnapshot = nil
        case .markdown:
            guard let markdownPanel = panel as? MarkdownPanel else { return nil }
            terminalSnapshot = nil
            browserSnapshot = nil
            markdownSnapshot = SessionMarkdownPanelSnapshot(filePath: markdownPanel.filePath)
            filePreviewSnapshot = nil
            rightSidebarToolSnapshot = nil
            agentSessionSnapshot = nil
            projectSnapshot = nil
        case .filePreview:
            guard let filePreviewPanel = panel as? FilePreviewPanel else { return nil }
            terminalSnapshot = nil
            browserSnapshot = nil
            markdownSnapshot = nil
            filePreviewSnapshot = SessionFilePreviewPanelSnapshot(filePath: filePreviewPanel.filePath)
            rightSidebarToolSnapshot = nil
            agentSessionSnapshot = nil
            projectSnapshot = nil
        case .rightSidebarTool:
            guard let toolPanel = panel as? RightSidebarToolPanel else { return nil }
            terminalSnapshot = nil
            browserSnapshot = nil
            markdownSnapshot = nil
            filePreviewSnapshot = nil
            rightSidebarToolSnapshot = SessionRightSidebarToolPanelSnapshot(mode: toolPanel.mode)
            agentSessionSnapshot = nil
            projectSnapshot = nil
        case .agentSession:
            guard let agentPanel = panel as? AgentSessionPanel else { return nil }
            terminalSnapshot = nil
            browserSnapshot = nil
            markdownSnapshot = nil
            filePreviewSnapshot = nil
            rightSidebarToolSnapshot = nil
            agentSessionSnapshot = SessionAgentSessionPanelSnapshot(
                rendererKind: agentPanel.rendererKind,
                providerID: agentPanel.currentProviderID,
                workingDirectory: directory
            )
            projectSnapshot = nil
        case .project:
            guard let projectPanel = panel as? ProjectPanel else { return nil }
            terminalSnapshot = nil
            browserSnapshot = nil
            markdownSnapshot = nil
            filePreviewSnapshot = nil
            rightSidebarToolSnapshot = nil
            projectSnapshot = SessionProjectPanelSnapshot(
                projectPath: projectPanel.projectURL.path,
                selectedNodePath: projectPanel.selectedFilePath,
                activeTab: projectPanel.activeTab.rawValue,
                selectedSchemeName: projectPanel.selectedSchemeName,
                selectedConfigurationName: projectPanel.selectedConfigurationName
            )
            agentSessionSnapshot = nil
        case .extensionBrowser:
            return nil
        }

        return SessionPanelSnapshot(
            id: panelId,
            type: panel.panelType,
            title: panelTitle,
            customTitle: customTitle,
            directory: directory,
            isPinned: isPinned,
            isManuallyUnread: isManuallyUnread,
            hasUnreadIndicator: hasUnreadIndicator,
            restoredUnreadContributesToWorkspace: restoredUnreadContributesToWorkspace,
            notifications: panelNotificationSnapshots.isEmpty ? nil : panelNotificationSnapshots,
            gitBranch: branchSnapshot,
            listeningPorts: listeningPorts,
            ttyName: ttyName,
            terminal: terminalSnapshot,
            browser: browserSnapshot,
            markdown: markdownSnapshot,
            filePreview: filePreviewSnapshot,
            rightSidebarTool: rightSidebarToolSnapshot,
            agentSession: agentSessionSnapshot,
            project: projectSnapshot
        )
    }

}
