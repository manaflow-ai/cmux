import CmuxAppKitSupportUI
import CmuxFoundation
import Foundation
import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteSession
import CmuxRemoteWorkspace
import CmuxWorkspaces
import CmuxTerminal
import CmuxTerminalCore
import SwiftUI
import AppKit
import CmuxFoundation
import Bonsplit
import CMUXAgentLaunch
import CmuxSettings
import CmuxBrowser
import CmuxCanvasUI
import CmuxPanes
import CmuxSidebar
import CmuxNotifications
import Combine
import CryptoKit
import Darwin
import Network
import CoreText

private struct SessionPaneRestoreEntry {
    let paneId: PaneID
    let snapshot: SessionPaneLayoutSnapshot
}


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

        // The ordered, first-source-wins de-duplicated, capped panel-id merge
        // lives in CmuxWorkspaces behind the SessionRestoreCoordinator; Workspace
        // gathers the two live source lists (sidebar order, then the remaining
        // live panel ids sorted by uuidString) and the wire/persistence cap.
        let allPanelIds = sessionRestoreCoordinator.persistedPanelIdOrder(
            sidebarOrdered: sidebarOrderedPanelIds(),
            remaining: panels.keys.sorted(by: { $0.uuidString < $1.uuidString }),
            limit: SessionPersistencePolicy.maxPanelsPerWorkspace
        )

        let panelSnapshots = allPanelIds
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
        let notificationStore = hostEnvironment?.notificationStore
        let isWorkspaceManuallyUnread = notificationStore?.hasManualUnread(forTabId: id) ?? false
        let hasWorkspaceUnreadIndicator =
            (notificationStore?.hasUnreadNotification(forTabId: id, surfaceId: nil) ?? false) ||
            (notificationStore?.hasRestoredUnreadIndicator(forTabId: id) ?? false)
        let workspaceNotificationSnapshots = notificationSnapshots(surfaceId: nil)

        return SessionWorkspaceSnapshot(
            workspaceId: id,
            processTitle: processTitle,
            customTitle: customTitle,
            customTitleSource: effectiveCustomTitleSource,
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
            layoutMode: layoutMode.rawValue,
            canvasPanes: canvasSessionPaneSnapshots(),
            panels: panelSnapshots,
            statusEntries: statusSnapshots,
            logEntries: logSnapshots,
            progress: progressSnapshot,
            gitBranch: gitBranchSnapshot,
            remote: remoteConfiguration?.sessionSnapshot(),
            environment: workspaceEnvironment.isEmpty ? nil : workspaceEnvironment
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
            let shouldAutoConnect = sessionRestorePolicy.shouldAutoConnectRestoredRemote(
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

        // Restore the per-workspace environment before any surface is rebuilt so
        // every restored terminal (all of which spawn fresh shells — PTYs do not
        // survive an app restart) inherits it through `newTerminalSurface`.
        workspaceEnvironment = Self.sanitizedWorkspaceEnvironment(snapshot.environment ?? [:])

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
        sessionRestoreCoordinator.applySessionDividerPositions(
            snapshotNode: snapshot.layout,
            liveNode: bonsplitController.treeSnapshot()
        )

        applyProcessTitle(snapshot.processTitle)
        setCustomTitle(snapshot.customTitle, source: snapshot.customTitleSource ?? .user)
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

        restoreCanvasState(from: snapshot, oldToNewPanelIds: oldToNewPanelIds)

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
            hostEnvironment?.notificationStore?.restoreUnreadIndicator(forTabId: id)
        } else {
            hostEnvironment?.notificationStore?.clearRestoredUnreadIndicator(forTabId: id)
        }
        hostEnvironment?.notificationStore?.restoreSessionNotifications(restoredNotifications, forTabId: id)
        syncUnreadBadgeStateForAllPanels()
        return oldToNewPanelIds
    }

    private func sessionLayoutSnapshot(from node: ExternalTreeNode) -> SessionWorkspaceLayoutSnapshot {
        // The live-tree → persisted-layout transform lives in CmuxWorkspaces
        // behind the SessionRestoreCoordinator; Workspace hosts the surface-id
        // map it reads via WorkspaceSessionRestoreHosting.
        sessionRestoreCoordinator.sessionLayoutSnapshot(from: node)
    }

    private func prunedSessionLayoutSnapshot(
        _ node: SessionWorkspaceLayoutSnapshot,
        keeping panelIdsToKeep: Set<UUID>
    ) -> SessionWorkspaceLayoutSnapshot? {
        // The recursive prune algorithm lives in CmuxWorkspaces behind the
        // SessionLayoutPruning seam; SessionWorkspaceLayoutSnapshot conforms
        // in the app target, keeping the wire format owned here.
        node.sessionLayoutPruned(keeping: panelIdsToKeep)
    }

    private func sessionPanelSnapshot(
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
        let customTitleSource: CustomTitleSource? = customTitle != nil
            ? (panelCustomTitleSources[panelId] ?? .user)
            : nil
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
                ? sessionRestorePolicy.restorableTmuxStartCommand(terminalPanel.surface.debugTmuxStartCommand())
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
            let resumeStartupInput = sessionRestorePolicy.surfaceResumeStartupInput(
                resumeBinding,
                autoResumeAgentSessions: AgentSessionAutoResumeSettings.isEnabled() && (agentWasRunning ?? true),
                promptForApproval: false,
                approvalStoreURL: SurfaceResumeApprovalStore.defaultURL()
            )
            let closeConfirmationRequired = Self.resolveCloseConfirmation(
                shellActivityState: panelShellActivityStates[panelId],
                fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose()
            )
            let shouldPersistScrollback = sessionRestorePolicy.shouldPersistSessionScrollback(
                closeConfirmationRequired: closeConfirmationRequired
            ) && sessionRestorePolicy.shouldReplaySessionScrollback(
                hasRestorableAgent: effectiveRestorableAgent != nil,
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
                    lineLimit: ScrollbackTruncation().maxLines
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
            customTitleSource: customTitleSource,
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

    private func closedPanelHistoryEntry(panelId: UUID, tabId: TabID, pane: PaneID) -> ClosedPanelHistoryEntry? {
        guard !suppressClosedPanelHistory else { return nil }
        guard let tabIndex = bonsplitController.tabs(inPane: pane).firstIndex(where: { $0.id == tabId }) else {
            return nil
        }
        let paneTabs = bonsplitController.tabs(inPane: pane)
        // The neighbor-selection rule (prefer the next tab, fall back to the
        // previous, none when the closing tab is alone) lives in
        // SessionRestoreCoordinator; Workspace resolves the chosen tab's surface
        // id to its panel id against the live pane-tree state.
        let paneAnchorPanelId: UUID? = sessionRestoreCoordinator
            .paneAnchorNeighborIndex(forClosedTabIndex: tabIndex, tabCount: paneTabs.count)
            .flatMap { panelIdFromSurfaceId(paneTabs[$0].id) }
        let fallbackPlan = bonsplitController.treeSnapshot().browserCloseFallbackPlan(
            forPaneId: pane.id.uuidString
        )
        let fallbackAnchorPanelId = fallbackPlan?.anchorPaneId.flatMap { anchorPaneId -> UUID? in
            guard let anchorPane = bonsplitController.allPaneIds.first(where: { $0.id == anchorPaneId }),
                  let anchorTab = bonsplitController.selectedTab(inPane: anchorPane)
                    ?? bonsplitController.tabs(inPane: anchorPane).first else {
                return nil
            }
            return panelIdFromSurfaceId(anchorTab.id)
        }
        let fallbackSplitPlacement = fallbackPlan.map {
            ClosedPanelSplitPlacement(
                orientation: $0.orientation,
                insertFirst: $0.insertFirst,
                anchorPanelId: fallbackAnchorPanelId
            )
        }
        // Prefer the warm cached agent index over a synchronous
        // `RestorableAgentSessionIndex.load()` (sysctl-per-record + disk, ~350ms-1.8s on
        // machines with large agent history) so closing a tab does not freeze the main
        // thread. Fall back to a fresh load only when the cache has not loaded yet (the
        // brief window after launch before the first refresh completes; the cache is
        // prewarmed at launch so this is rare). A cached entry at most one refresh stale
        // is acceptable here because restore prefers the always-fresh in-memory
        // resumeBinding and only consults this agent snapshot when no binding exists, so
        // cmux-launched agents reopen correctly regardless of cache freshness.
        let agentIndex = SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh()
            ?? RestorableAgentSessionIndex.load()
        let restorableAgent = agentIndex.snapshot(workspaceId: id, panelId: panelId)
        guard let snapshot = sessionPanelSnapshot(
            panelId: panelId,
            includeScrollback: true,
            restorableAgent: restorableAgent,
            resumeBinding: effectiveSurfaceResumeBinding(
                panelId: panelId,
                surfaceResumeBindingIndex: nil
            )
        ) else {
            return nil
        }
        return ClosedPanelHistoryEntry(
            workspaceId: id,
            paneId: pane.id,
            paneAnchorPanelId: paneAnchorPanelId,
            tabIndex: tabIndex,
            snapshot: snapshot,
            fallbackSplitPlacement: fallbackSplitPlacement
        )
    }

    private func consumeCloseHistoryEligibility(tabId: TabID, panelId: UUID?) -> Bool {
        surfaceRegistry.consumeCloseHistoryEligibility(tabId: tabId, panelId: panelId)
    }

    private func clearCloseHistoryEligibility(tabId: TabID, panelId: UUID? = nil) {
        surfaceRegistry.clearCloseHistoryEligibility(
            tabId: tabId,
            panelId: panelId ?? panelIdFromSurfaceId(tabId)
        )
    }

    @discardableResult
    private func pushClosedPanelHistoryIfEligible(for tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        guard !suppressClosedPanelHistory else { return false }
        guard let panelId = panelIdFromSurfaceId(tab.id) else { return false }
        guard consumeCloseHistoryEligibility(tabId: tab.id, panelId: panelId) else { return false }
        guard let entry = closedPanelHistoryEntry(panelId: panelId, tabId: tab.id, pane: pane) else {
            return false
        }
        ClosedItemHistoryStore.shared.push(.panel(entry))
        return true
    }

    @discardableResult
    func restoreClosedPanel(_ entry: ClosedPanelHistoryEntry) -> UUID? {
        if entry.restoreInOriginalPane,
           let originalPane = bonsplitController.allPaneIds.first(where: { $0.id == entry.paneId }) {
            return restoreClosedPanel(entry, inPane: originalPane)
        }
        if let paneAnchorPanelId = entry.paneAnchorPanelId,
           let pane = paneId(forPanelId: paneAnchorPanelId) {
            return restoreClosedPanel(entry, inPane: pane)
        }
        if let splitPanelId = restoreClosedPanelInFallbackSplit(entry) {
            triggerFocusFlash(panelId: splitPanelId)
            return splitPanelId
        }
        guard let pane = bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first else {
            return nil
        }
        return restoreClosedPanel(entry, inPane: pane)
    }

    @discardableResult
    private func restoreClosedPanel(_ entry: ClosedPanelHistoryEntry, inPane pane: PaneID) -> UUID? {
        guard let panelId = createPanel(
            from: entry.snapshot,
            inPane: pane,
            snapshotWorkspaceId: nil
        ) else { return nil }

        let maxIndex = max(0, bonsplitController.tabs(inPane: pane).count - 1)
        _ = reorderSurface(panelId: panelId, toIndex: min(max(entry.tabIndex, 0), maxIndex))
        if let tabId = surfaceIdFromPanelId(panelId) {
            bonsplitController.focusPane(pane)
            bonsplitController.selectTab(tabId)
        }
        focusPanel(panelId)
        triggerFocusFlash(panelId: panelId)
        return panelId
    }

    @discardableResult
    private func restoreClosedPanelInFallbackSplit(_ entry: ClosedPanelHistoryEntry) -> UUID? {
        guard let placement = entry.fallbackSplitPlacement,
              let anchorPanelId = placement.anchorPanelId,
              panels[anchorPanelId] != nil else {
            return nil
        }

        guard let placeholderPanel = newTerminalSplit(
            from: anchorPanelId,
            orientation: placement.orientation,
            insertFirst: placement.insertFirst,
            focus: false
        ) else {
            return nil
        }
        guard let pane = paneId(forPanelId: placeholderPanel.id) else {
            _ = closePanel(placeholderPanel.id, force: true)
            return nil
        }

        guard let panelId = createPanel(
            from: entry.snapshot,
            inPane: pane,
            snapshotWorkspaceId: nil
        ) else {
            _ = closePanel(placeholderPanel.id, force: true)
            return nil
        }

        _ = closePanel(placeholderPanel.id, force: true)
        guard panels[panelId] != nil else {
            return nil
        }
        focusPanel(panelId)
        return panelId
    }

    nonisolated static func resolvedSnapshotTerminalScrollback(
        capturedScrollback: String?,
        fallbackScrollback: String?,
        allowFallbackScrollback: Bool = true
    ) -> String? {
        makeSessionRestorePolicyService().resolvedSnapshotTerminalScrollback(
            capturedScrollback: capturedScrollback,
            fallbackScrollback: fallbackScrollback,
            allowFallbackScrollback: allowFallbackScrollback
        )
    }

    nonisolated static func shouldReplaySessionScrollback(
        restorableAgent: SessionRestorableAgentSnapshot?,
        tmuxStartCommand: String? = nil,
        hasResumeStartupWork: Bool = false
    ) -> Bool {
        makeSessionRestorePolicyService().shouldReplaySessionScrollback(
            hasRestorableAgent: restorableAgent != nil,
            tmuxStartCommand: tmuxStartCommand,
            hasResumeStartupWork: hasResumeStartupWork
        )
    }

    nonisolated static func shouldAutoConnectRestoredRemote(
        foregroundAuthToken: String?,
        snapshot: SessionWorkspaceSnapshot,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy().isRunningUnderAutomatedTests
    ) -> Bool {
        makeSessionRestorePolicyService().shouldAutoConnectRestoredRemote(
            foregroundAuthToken: foregroundAuthToken,
            snapshot: snapshot,
            isRunningUnderAutomatedTests: isRunningUnderAutomatedTests
        )
    }

    nonisolated static func surfaceResumeStartupInput(
        _ resumeBinding: SurfaceResumeBindingSnapshot?,
        autoResumeAgentSessions: Bool,
        allowLauncherScript: Bool = false,
        promptForApproval: Bool = true,
        approvalStoreURL: URL = SurfaceResumeApprovalStore.defaultURL(),
        approvalSigningSecret: Data? = nil
    ) -> String? {
        makeSessionRestorePolicyService().surfaceResumeStartupInput(
            resumeBinding,
            autoResumeAgentSessions: autoResumeAgentSessions,
            allowLauncherScript: allowLauncherScript,
            promptForApproval: promptForApproval,
            approvalStoreURL: approvalStoreURL,
            approvalSigningSecret: approvalSigningSecret
        )
    }

    nonisolated static func surfaceResumeStartupLaunch(
        _ resumeBinding: SurfaceResumeBindingSnapshot?,
        autoResumeAgentSessions: Bool,
        allowLauncherScript: Bool = true,
        promptForApproval: Bool = true,
        approvalStoreURL: URL = SurfaceResumeApprovalStore.defaultURL(),
        approvalSigningSecret: Data? = nil,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> SurfaceResumeStartupLaunch? {
        makeSessionRestorePolicyService(
            temporaryDirectory: temporaryDirectory
        ).surfaceResumeStartupLaunch(
            resumeBinding,
            autoResumeAgentSessions: autoResumeAgentSessions,
            allowLauncherScript: allowLauncherScript,
            promptForApproval: promptForApproval,
            approvalStoreURL: approvalStoreURL,
            approvalSigningSecret: approvalSigningSecret,
            fileManager: fileManager
        )
    }

    nonisolated static func restorableTmuxStartCommand(_ rawCommand: String?) -> String? {
        makeSessionRestorePolicyService().restorableTmuxStartCommand(rawCommand)
    }

    nonisolated static func shouldPersistSessionScrollback(
        shellActivityState: PanelShellActivityState?,
        fallbackNeedsConfirmClose: Bool
    ) -> Bool {
        makeSessionRestorePolicyService().shouldPersistSessionScrollback(
            closeConfirmationRequired: resolveCloseConfirmation(
                shellActivityState: shellActivityState,
                fallbackNeedsConfirmClose: fallbackNeedsConfirmClose
            )
        )
    }

    private func terminalSnapshotScrollback(
        panelId: UUID,
        capturedScrollback: String?,
        includeScrollback: Bool,
        allowFallbackScrollback: Bool = true
    ) -> String? {
        guard includeScrollback else { return nil }
#if DEBUG
        let debugFallback = debugSessionSnapshotScrollbackFallbackPanelIds.contains(panelId)
            ? debugSessionSnapshotSyntheticScrollbackByPanelId[panelId]
            : nil
#else
        let debugFallback: String? = nil
#endif
        let fallback = allowFallbackScrollback
            ? (debugFallback ?? restoredTerminalScrollbackByPanelId[panelId])
            : nil
        let resolved = sessionRestorePolicy.resolvedSnapshotTerminalScrollback(
            capturedScrollback: capturedScrollback,
            fallbackScrollback: fallback,
            allowFallbackScrollback: allowFallbackScrollback
        )
#if DEBUG
        if debugFallback != nil {
            debugSessionSnapshotScrollbackFallbackPanelIds.remove(panelId)
            debugSessionSnapshotSyntheticScrollbackByPanelId.removeValue(forKey: panelId)
            return resolved
        }
#endif
        if let resolved {
            restoredTerminalScrollbackByPanelId[panelId] = resolved
        } else {
            restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
        }
        return resolved
    }

#if DEBUG
    func debugSeedSessionSnapshotScrollback(charactersPerTerminal: Int) -> (terminals: Int, characters: Int) {
        for panelId in debugSessionSnapshotScrollbackFallbackPanelIds {
            debugSessionSnapshotSyntheticScrollbackByPanelId.removeValue(forKey: panelId)
        }
        debugSessionSnapshotScrollbackFallbackPanelIds.removeAll(keepingCapacity: false)
        debugSessionSnapshotSyntheticScrollbackByPanelId.removeAll(keepingCapacity: false)

        let targetCharacters = min(
            max(0, charactersPerTerminal),
            ScrollbackTruncation().maxCharacters
        )
        guard targetCharacters > 0 else { return (0, 0) }

        var terminalCount = 0
        var totalCharacters = 0
        for panelId in panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard panels[panelId] is TerminalPanel else { continue }
            let header = "cmux perf synthetic scrollback workspace=\(id.uuidString) panel=\(panelId.uuidString)\n"
            let paddingCount = max(0, targetCharacters - header.count)
            let scrollback = String((header + String(repeating: "s", count: paddingCount)).prefix(targetCharacters))
            debugSessionSnapshotSyntheticScrollbackByPanelId[panelId] = scrollback
            debugSessionSnapshotScrollbackFallbackPanelIds.insert(panelId)
            terminalCount += 1
            totalCharacters += scrollback.count
        }
        return (terminalCount, totalCharacters)
    }
#endif

    private func restoreSessionLayout(_ layout: SessionWorkspaceLayoutSnapshot) -> [SessionPaneRestoreEntry] {
        guard let rootPaneId = bonsplitController.allPaneIds.first else {
            return []
        }

        var leaves: [SessionPaneRestoreEntry] = []
        restoreSessionLayoutNode(layout, inPane: rootPaneId, leaves: &leaves)
        return leaves
    }

    private func restoreSessionLayoutNode(
        _ node: SessionWorkspaceLayoutSnapshot,
        inPane paneId: PaneID,
        leaves: inout [SessionPaneRestoreEntry]
    ) {
        switch node {
        case .pane(let pane):
            leaves.append(SessionPaneRestoreEntry(paneId: paneId, snapshot: pane))
        case .split(let split):
            var anchorPanelId = bonsplitController
                .tabs(inPane: paneId)
                .compactMap { panelIdFromSurfaceId($0.id) }
                .first

            if anchorPanelId == nil {
                anchorPanelId = newTerminalSurface(inPane: paneId, focus: false)?.id
            }

            guard let anchorPanelId,
                  let newSplitPanel = newTerminalSplit(
                    from: anchorPanelId,
                    orientation: split.orientation.splitOrientation,
                    insertFirst: false,
                    focus: false
                  ),
                  let secondPaneId = self.paneId(forPanelId: newSplitPanel.id) else {
                leaves.append(
                    SessionPaneRestoreEntry(
                        paneId: paneId,
                        snapshot: SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)
                    )
                )
                return
            }

            restoreSessionLayoutNode(split.first, inPane: paneId, leaves: &leaves)
            restoreSessionLayoutNode(split.second, inPane: secondPaneId, leaves: &leaves)
        }
    }

    private func restorePane(
        _ paneId: PaneID,
        snapshot: SessionPaneLayoutSnapshot,
        panelSnapshotsById: [UUID: SessionPanelSnapshot],
        snapshotWorkspaceId: UUID?,
        oldToNewPanelIds: inout [UUID: UUID]
    ) {
        let existingPanelIds = bonsplitController
            .tabs(inPane: paneId)
            .compactMap { panelIdFromSurfaceId($0.id) }
        let desiredOldPanelIds = snapshot.panelIds.filter { panelSnapshotsById[$0] != nil }

        var createdPanelIds: [UUID] = []
        for oldPanelId in desiredOldPanelIds {
            guard let panelSnapshot = panelSnapshotsById[oldPanelId] else { continue }
            guard let createdPanelId = createPanel(
                from: panelSnapshot,
                inPane: paneId,
                snapshotWorkspaceId: snapshotWorkspaceId
            ) else { continue }
            createdPanelIds.append(createdPanelId)
            oldToNewPanelIds[oldPanelId] = createdPanelId
        }

        guard !createdPanelIds.isEmpty else { return }

        for oldPanelId in existingPanelIds where !createdPanelIds.contains(oldPanelId) {
            _ = closePanel(oldPanelId, force: true)
        }

        for (index, panelId) in createdPanelIds.enumerated() {
            _ = reorderSurface(panelId: panelId, toIndex: index)
        }

        let selectedPanelId: UUID? = {
            if let selectedOldId = snapshot.selectedPanelId {
                return oldToNewPanelIds[selectedOldId]
            }
            return createdPanelIds.first
        }()

        if let selectedPanelId,
           let selectedTabId = surfaceIdFromPanelId(selectedPanelId) {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(selectedTabId)
        }
    }

    func reconcileSurfaceResumeBindings(using surfaceResumeBindingIndex: SurfaceResumeBindingIndex) {
        // The per-panel stored-vs-detected decision lives in
        // SessionRestoreCoordinator (CmuxWorkspaces); the live panel set and the
        // stored binding map are Workspace-owned live state, so the iteration and
        // map mutation stay here and apply the coordinator's decision.
        for panelId in panels.keys {
            let storedBinding = surfaceResumeBindingsByPanelId[panelId]
            let detectedBinding = surfaceResumeBindingIndex.binding(workspaceId: id, panelId: panelId)
            switch sessionRestoreCoordinator.reconcileResumeBinding(
                stored: storedBinding,
                detected: detectedBinding
            ) {
            case .keep:
                continue
            case .store(let binding):
                surfaceResumeBindingsByPanelId[panelId] = binding
            case .remove:
                surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
            }
        }
    }

    func effectiveSurfaceResumeBinding(
        panelId: UUID,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex?
    ) -> SurfaceResumeBindingSnapshot? {
        // The resolution logic lives in SessionRestoreCoordinator
        // (CmuxWorkspaces); Workspace gathers the live stored/detected bindings.
        sessionRestoreCoordinator.effectiveResumeBinding(
            stored: surfaceResumeBindingsByPanelId[panelId],
            detected: surfaceResumeBindingIndex?.binding(workspaceId: id, panelId: panelId),
            hasDetectionSource: surfaceResumeBindingIndex != nil
        )
    }

    private func createPanel(
        from snapshot: SessionPanelSnapshot,
        inPane paneId: PaneID,
        snapshotWorkspaceId: UUID?
    ) -> UUID? {
        switch snapshot.type {
        case .terminal:
            let resumeBinding = snapshot.terminal?.resumeBinding
            let restorableAgent = snapshot.terminal?.agent
            let restoredHibernation = snapshot.terminal?.hibernation
            let autoResumeAgentSessions = AgentSessionAutoResumeSettings.isEnabled()
            // Only auto-resume if the agent was actively running when the snapshot was saved.
            // wasAgentRunning == nil means a legacy snapshot; treat as true for backwards compatibility.
            let agentWasRunningAtQuit = snapshot.terminal?.wasAgentRunning ?? true
            let shouldAutoResumeAgent = autoResumeAgentSessions && agentWasRunningAtQuit
            let resumeBindingForStartup =
                restoredHibernation != nil ||
                (resumeBinding?.isProcessDetected == true && resumeBinding?.autoResume != true)
                    ? nil
                    : resumeBinding
            let effectiveResumeBindingForStartup = sessionRestorePolicy.approvedSurfaceResumeBinding(
                resumeBindingForStartup,
                autoResumeAgentSessions: shouldAutoResumeAgent,
                promptForApproval: true,
                approvalStoreURL: SurfaceResumeApprovalStore.defaultURL()
            )
            let remoteStartupCommand = remoteTerminalStartupCommand()
            let restoredBindingLaunch: SurfaceResumeStartupLaunch? = if remoteStartupCommand != nil {
                effectiveResumeBindingForStartup?
                    .startupInputWithLauncherScript(allowLauncherScript: false)
                    .map(SurfaceResumeStartupLaunch.input)
            } else {
                effectiveResumeBindingForStartup.flatMap {
                    sessionRestorePolicy.surfaceResumeStartupLaunch(
                        forApprovedBinding: $0,
                        allowLauncherScript: true
                    )
                }
            }
            let effectiveResumeBinding = restoredBindingLaunch == nil ? nil : resumeBinding
            let savedWorkingDirectory =
                effectiveResumeBinding?.cwd
                ?? snapshot.terminal?.workingDirectory
                ?? restorableAgent?.workingDirectory
                ?? snapshot.directory
            let workingDirectory = savedWorkingDirectory
                ?? currentDirectory
            let restorableTmuxStartCommand = restorableAgent == nil && restoredBindingLaunch == nil
                ? sessionRestorePolicy.restorableTmuxStartCommand(snapshot.terminal?.tmuxStartCommand)
                : nil
            let restoredTmuxStartupScript = restorableTmuxStartCommand.flatMap {
                SessionRestoredTerminalCommandStore.writeLauncherScript(
                    command: $0,
                    workingDirectory: workingDirectory
                )
            }
            let restoredTmuxStartCommand = restoredTmuxStartupScript == nil ? nil : restorableTmuxStartCommand
            let restoredAgentResumeLaunch: SurfaceResumeStartupLaunch? =
                if shouldAutoResumeAgent && restoredHibernation == nil && restoredBindingLaunch == nil {
                    if remoteStartupCommand != nil {
                        restorableAgent?.resumeStartupInput(
                            allowLauncherScript: false,
                            allowOversizedInlineInput: true
                        )
                            .map(SurfaceResumeStartupLaunch.input)
                    } else {
                        restorableAgent?.resumeStartupCommand()
                            .map(SurfaceResumeStartupLaunch.command)
                    }
                } else {
                    nil
                }
            let shouldReplayScrollback = sessionRestorePolicy.shouldReplaySessionScrollback(
                hasRestorableAgent: restorableAgent != nil,
                tmuxStartCommand: restoredTmuxStartCommand,
                hasResumeStartupWork: restoredBindingLaunch != nil || restoredAgentResumeLaunch != nil
            )
            let restoredRemotePTYSessionID: String? = {
                guard remoteConfiguration?.preserveAfterTerminalExit == true,
                      remoteConfiguration?.persistentDaemonSlot != nil else {
                    return nil
                }
                if let remotePTYSessionID = normalizedRemotePTYSessionID(snapshot.terminal?.remotePTYSessionID) {
                    return remotePTYSessionID
                }
                guard snapshot.terminal?.isRemoteTerminal == true else {
                    return nil
                }
                return Self.defaultSSHPTYSessionID(workspaceId: snapshotWorkspaceId ?? id, panelId: snapshot.id)
            }()
            let restoredRemotePTYAttachCommand = restoredRemotePTYSessionID.map {
                remotePTYAttachStartupCommand(sessionID: $0)
            }
            let restoredStartupCommand =
                restoredRemotePTYAttachCommand
                ?? restoredTmuxStartupScript?.path
                ?? restoredBindingLaunch?.initialCommand
                ?? restoredAgentResumeLaunch?.initialCommand
            let restoredStartupInput = restoredRemotePTYAttachCommand == nil
                ? (restoredBindingLaunch?.initialInput ?? restoredAgentResumeLaunch?.initialInput)
                : nil
            let startupHandlesWorkingDirectory =
                restoredTmuxStartupScript != nil ||
                restoredAgentResumeLaunch != nil ||
                (restoredBindingLaunch != nil && resumeBinding?.isAgentHookBinding == true)
            // Guarded startup commands cd themselves and tolerate deleted saved directories.
            // Passing the same cwd to Ghostty can fail before the guarded command runs.
            let suppressWorkspaceRemoteStartupCommand =
                remoteConfiguration != nil &&
                snapshot.terminal?.isRemoteTerminal == false &&
                restoredRemotePTYAttachCommand == nil
            let effectiveRemoteStartupCommand = suppressWorkspaceRemoteStartupCommand ? nil : remoteStartupCommand
            let restoresRemoteWorkspaceTerminalSnapshot =
                remoteConfiguration != nil && snapshot.terminal?.isRemoteTerminal == true
            let localWorkingDirectory = effectiveRemoteStartupCommand == nil &&
                restoredRemotePTYAttachCommand == nil &&
                !restoresRemoteWorkspaceTerminalSnapshot &&
                !startupHandlesWorkingDirectory
                ? (suppressWorkspaceRemoteStartupCommand ? savedWorkingDirectory : workingDirectory)
                : nil
            let restoredAgentWillRunStartupCommand = restorableAgent != nil && (
                restoredAgentResumeLaunch?.initialCommand != nil ||
                (restoredBindingLaunch?.initialCommand != nil && resumeBinding?.isAgentHookBinding == true)
            )
            let restoredAgentWillRunStartupInput = restorableAgent != nil && (
                restoredAgentResumeLaunch?.initialInput != nil ||
                (restoredBindingLaunch?.initialInput != nil && resumeBinding?.isAgentHookBinding == true)
            )
#if DEBUG
            if let restorableAgent {
                let sessionPreview = String(restorableAgent.sessionId.prefix(8))
                let launchArgc = restorableAgent.launchCommand?.arguments.count ?? 0
                cmuxDebugLog(
                    "session.restore.agent panel=\(snapshot.id.uuidString.prefix(5)) " +
                    "kind=\(restorableAgent.kind.rawValue) session=\(sessionPreview) " +
                    "hasLaunch=\(restorableAgent.launchCommand == nil ? 0 : 1) " +
                    "launchArgc=\(launchArgc) hasResume=\(restoredAgentResumeLaunch == nil ? 0 : 1) " +
                    "autoResume=\(autoResumeAgentSessions ? 1 : 0) " +
                    "replayScrollback=\(shouldReplayScrollback ? 1 : 0)"
                )
            }
            if let resumeBinding {
                cmuxDebugLog(
                    "session.restore.surfaceResume panel=\(snapshot.id.uuidString.prefix(5)) " +
                    "kind=\(resumeBinding.kind ?? "unknown") source=\(resumeBinding.source ?? "unknown") " +
                    "hasLaunch=\(restoredBindingLaunch == nil ? 0 : 1) " +
                    "replayScrollback=\(shouldReplayScrollback ? 1 : 0)"
                )
            }
#endif
            let shouldReplayLocalScrollback = restoredRemotePTYAttachCommand == nil && shouldReplayScrollback
            let restoredScrollback = shouldReplayLocalScrollback ? snapshot.terminal?.scrollback : nil
            let replayEnvironment = SessionScrollbackReplay().replayEnvironment(for: restoredScrollback)
            // Reuse the persisted surface id so the restored terminal keeps
            // the same identity (the panel/surface id IS the ghostty surface
            // id), which keeps agent-session terminal bindings valid across
            // relaunch/restore. Only reuse when no live surface already holds
            // that id (duplicate-workspace / restore-into-live can collide);
            // otherwise fall back to a fresh id and let the old->new remap
            // handle it, exactly as before.
            let reusableSurfaceId: UUID? =
                GhosttyApp.terminalSurfaceRegistry.surface(id: snapshot.id) == nil ? snapshot.id : nil
            guard let terminalPanel = newTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: localWorkingDirectory,
                initialCommand: restoredStartupCommand,
                tmuxStartCommand: restoredTmuxStartCommand,
                initialInput: restoredStartupInput,
                startupEnvironment: replayEnvironment,
                runtimeSpawnPolicy: .pacedSessionRestore,
                remotePTYSessionID: restoredRemotePTYSessionID,
                suppressWorkspaceRemoteStartupCommand: suppressWorkspaceRemoteStartupCommand,
                restoredSurfaceId: reusableSurfaceId
            ) else {
                return nil
            }
            if let restoredRemotePTYSessionID {
                registerRemoteRelayIDAliases(
                    remotePTYSessionID: restoredRemotePTYSessionID,
                    restoredPanelId: terminalPanel.id
                )
                registerRemoteRelayIDAliases(
                    snapshotWorkspaceId: snapshotWorkspaceId,
                    snapshotPanelId: snapshot.id,
                    restoredPanelId: terminalPanel.id
                )
            }
            if let storedResumeBinding = effectiveResumeBindingForStartup ?? resumeBinding {
                surfaceResumeBindingsByPanelId[terminalPanel.id] = storedResumeBinding
            } else {
                surfaceResumeBindingsByPanelId.removeValue(forKey: terminalPanel.id)
            }
            if startupHandlesWorkingDirectory,
               localWorkingDirectory == nil,
               let guardedWorkingDirectory = savedWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
               !guardedWorkingDirectory.isEmpty,
               WorkspaceSurfaceMetadataModel<PendingTabSelectionRequest>.unmountedVolumeRoot(
                   for: guardedWorkingDirectory
               ) != nil {
                restoredGuardedWorkingDirectoriesByPanelId[terminalPanel.id] = guardedWorkingDirectory
            } else {
                restoredGuardedWorkingDirectoriesByPanelId.removeValue(forKey: terminalPanel.id)
            }
            let fallbackScrollback = ScrollbackTruncation().truncated(restoredScrollback)
            if let fallbackScrollback {
                restoredTerminalScrollbackByPanelId[terminalPanel.id] = fallbackScrollback
            } else {
                restoredTerminalScrollbackByPanelId.removeValue(forKey: terminalPanel.id)
            }
            if let restorableAgent {
                restoredAgentSnapshotsByPanelId[terminalPanel.id] = restorableAgent
                if restoredAgentWillRunStartupCommand {
                    restoredAgentResumeStatesByPanelId[terminalPanel.id] = .autoResumeCommandRunning
                } else if restoredAgentWillRunStartupInput {
                    restoredAgentResumeStatesByPanelId[terminalPanel.id] = .awaitingAutoResumeCommand
                } else {
                    restoredAgentResumeStatesByPanelId[terminalPanel.id] = .manualResumeAvailable
                }
                invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: terminalPanel.id)
                if let restoredHibernation,
                   restorableAgent.resumeCommand != nil {
                    terminalPanel.enterAgentHibernation(
                        agent: restorableAgent,
                        lastActivityAt: Date(timeIntervalSince1970: restoredHibernation.lastActivityAt),
                        hibernatedAt: Date(timeIntervalSince1970: restoredHibernation.hibernatedAt)
                    )
                }
            } else {
                clearRestoredAgentSnapshot(panelId: terminalPanel.id)
                invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: terminalPanel.id)
            }
            terminalPanel.restoreSessionTextBoxDraft(snapshot.terminal?.textBoxDraft)
            applySessionPanelMetadata(snapshot, toPanelId: terminalPanel.id)
            return terminalPanel.id
        case .browser:
            guard let browserPanel = newBrowserSurface(
                inPane: paneId,
                url: nil,
                focus: false,
                preferredProfileID: snapshot.browser?.profileID,
                creationPolicy: .restoration,
                transparentBackground: snapshot.browser?.transparentBackground ?? false
            ) else {
                return nil
            }
            applySessionPanelMetadata(snapshot, toPanelId: browserPanel.id)
            return browserPanel.id
        case .markdown:
            guard let filePath = snapshot.markdown?.filePath,
                  let markdownPanel = newMarkdownSurface(
                    inPane: paneId,
                    filePath: filePath,
                    focus: false
                  ) else {
                return nil
            }
            applySessionPanelMetadata(snapshot, toPanelId: markdownPanel.id)
            return markdownPanel.id
        case .filePreview:
            guard let filePath = snapshot.filePreview?.filePath,
                  let filePreviewPanel = newFilePreviewSurface(
                    inPane: paneId,
                    filePath: filePath,
                    focus: false
                  ) else {
                return nil
            }
            applySessionPanelMetadata(snapshot, toPanelId: filePreviewPanel.id)
            return filePreviewPanel.id
        case .rightSidebarTool:
            guard let mode = snapshot.rightSidebarTool?.mode,
                  mode.canOpenAsPane,
                  let toolPanel = newRightSidebarToolSurface(
                    inPane: paneId,
                    mode: mode,
                    focus: false
                  ) else {
                return nil
            }
            applySessionPanelMetadata(snapshot, toPanelId: toolPanel.id)
            return toolPanel.id
        case .agentSession:
            guard let agentSession = snapshot.agentSession,
                  let agentPanel = newAgentSessionSurface(
                    inPane: paneId,
                    providerID: agentSession.providerID,
                    rendererKind: agentSession.rendererKind,
                    workingDirectory: agentSession.workingDirectory ?? snapshot.directory,
                    focus: false
                  ) else {
                return nil
            }
            applySessionPanelMetadata(snapshot, toPanelId: agentPanel.id)
            return agentPanel.id
        case .project:
            guard let projectPath = snapshot.project?.projectPath,
                  let projectPanel = newProjectSurface(
                    inPane: paneId,
                    projectPath: projectPath,
                    focus: false
                  ) else {
                return nil
            }
            applySessionPanelMetadata(snapshot, toPanelId: projectPanel.id)
            return projectPanel.id
        case .extensionBrowser:
            return nil
        }
    }

    private func applySessionPanelMetadata(_ snapshot: SessionPanelSnapshot, toPanelId panelId: UUID) {
        if let title = snapshot.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            panelTitles[panelId] = title
        }

        setPanelCustomTitle(panelId: panelId, title: snapshot.customTitle, source: snapshot.customTitleSource ?? .user)
        setPanelPinned(panelId: panelId, pinned: snapshot.isPinned)

        // The bonsplit tab header only refreshes when `updateTab` is called; the writes
        // above never reach it (`setPanelCustomTitle` skips the sync when there is no
        // custom title), so push the restored title to the tab now, mirroring
        // `updatePanelTitle`, instead of waiting for the next OSC title update.
        if let panel = panels[panelId], let tabId = surfaceIdFromPanelId(panelId) {
            bonsplitController.updateTab(
                tabId,
                title: resolvedPanelTitle(panelId: panelId, fallback: panelTitles[panelId] ?? panel.displayTitle),
                hasCustomTitle: panelCustomTitles[panelId] != nil
            )
        }

        if snapshot.isManuallyUnread {
            markPanelUnread(panelId)
        } else {
            clearManualUnread(panelId: panelId)
        }
        let hasUnreadPanelNotification = snapshot.notifications?.contains(where: { !$0.isRead }) == true
        if snapshot.hasUnreadIndicator == true, !hasUnreadPanelNotification {
            let contributesToWorkspaceUnread = snapshot.restoredUnreadContributesToWorkspace
                ?? (snapshot.notifications?.isEmpty ?? true)
            restorePanelUnreadIndicator(
                panelId,
                contributesToWorkspaceUnread: contributesToWorkspaceUnread
            )
        } else {
            clearRestoredUnreadIndicator(panelId: panelId)
        }

        if let directory = snapshot.directory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
            surfaceDirectoryMetadata.updatePanelDirectory(
                panelId: panelId,
                directory: directory,
                source: .restoredSnapshotMetadata
            )
        }

        if let branch = snapshot.gitBranch {
            panelGitBranches[panelId] = SidebarGitBranchState(branch: branch.branch, isDirty: branch.isDirty)
        } else {
            panelGitBranches.removeValue(forKey: panelId)
        }

        surfaceListeningPorts[panelId] = Array(Set(snapshot.listeningPorts)).sorted()

        if let ttyName = snapshot.ttyName?.trimmingCharacters(in: .whitespacesAndNewlines), !ttyName.isEmpty {
            surfaceTTYNames[panelId] = ttyName
        } else {
            surfaceTTYNames.removeValue(forKey: panelId)
        }
        syncRemotePortScanTTYs()

        if let browserSnapshot = snapshot.browser,
           let browserPanel = browserPanel(for: panelId) {
            let pageZoom = CGFloat(max(0.25, min(5.0, browserSnapshot.pageZoom)))
            if pageZoom.isFinite {
                _ = browserPanel.setPageZoomFactor(pageZoom)
            }

            browserPanel.restoreSessionSnapshot(browserSnapshot)
            syncBrowserAudioMuteStateForPanel(panelId, browserPanel: browserPanel)

            if browserSnapshot.developerToolsVisible && BrowserAvailabilitySettings.isEnabled() {
                _ = browserPanel.showDeveloperTools()
                browserPanel.requestDeveloperToolsRefreshAfterNextAttach(reason: "session_restore")
            } else {
                _ = browserPanel.hideDeveloperTools()
            }
        }
    }

    private func restoreWorkspaceManualUnread(_ isManuallyUnread: Bool) {
        guard let notificationStore = hostEnvironment?.notificationStore else { return }
        if isManuallyUnread {
            notificationStore.markUnread(forTabId: id)
        } else {
            notificationStore.clearManualUnread(forTabId: id)
        }
        syncUnreadBadgeStateForAllPanels()
    }

    private func notificationSnapshots(surfaceId: UUID?) -> [SessionNotificationSnapshot] {
        hostEnvironment?.notificationStore?
            .notifications(forTabId: id, surfaceId: surfaceId)
            .map(SessionNotificationSnapshot.init(notification:)) ?? []
    }

    private func restoredSessionNotifications(
        from snapshot: SessionWorkspaceSnapshot,
        oldToNewPanelIds: [UUID: UUID]
    ) -> [TerminalNotification] {
        var notifications = (snapshot.notifications ?? []).map {
            $0.terminalNotification(tabId: id, surfaceId: nil, panelId: nil)
        }

        for panelSnapshot in snapshot.panels {
            guard let newPanelId = oldToNewPanelIds[panelSnapshot.id] else { continue }
            notifications.append(
                contentsOf: (panelSnapshot.notifications ?? []).map {
                    $0.terminalNotification(
                        tabId: id,
                        surfaceId: newPanelId,
                        panelId: newPanelId
                    )
                }
            )
        }

        return notifications
    }

}

// MARK: - cmux.json custom layout

extension Workspace {

    /// Applies a cmux.json `layout` block to this freshly created workspace.
    /// Forwards to ``WorkspaceLayoutCoordinator`` (CmuxWorkspaces) after mapping
    /// the app-target `CmuxLayoutNode` onto the package's value image; the
    /// coordinator drives the split-tree build, surface population, divider
    /// positions, and focus back through ``WorkspaceLayoutHosting``.
    func applyCustomLayout(_ layout: CmuxLayoutNode, baseCwd: String) {
        layoutCoordinator.applyCustomLayout(layout.workspaceCustomLayoutNode, baseCwd: baseCwd)
    }

}


/// Live panel/surface seam for ``PendingTerminalInputCoordinator``. These
/// witnesses keep the app-target `TerminalPanel`, its `TerminalSurface`, and the
/// `.terminalSurfaceDidBecomeReady` notification app-side; the coordinator owns
/// only the pending surface-ready registry. Lifted verbatim from the legacy
/// `Workspace.sendInputWhenReady(_:to:)` body (surface-ready check, `sendInput`,
/// the not-ready observer registration, and `requestBackgroundSurfaceStartIfNeeded`).
extension Workspace {
    func pendingInputIsSurfaceReady(forPanelId panelId: UUID) -> Bool {
        guard let panel = panels[panelId] as? TerminalPanel else { return false }
        return panel.surface.surface != nil
    }

    func pendingInputSendInput(_ text: String, toPanelId panelId: UUID) {
        if let panel = panels[panelId] as? TerminalPanel {
            panel.sendInput(text)
        }
    }

    func pendingInputObserveSurfaceReady(
        forPanelId panelId: UUID,
        onReady: @escaping @Sendable () -> Void
    ) -> (any NSObjectProtocol)? {
        guard let panel = panels[panelId] as? TerminalPanel else { return nil }
        return NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: panel.surface,
            queue: .main
        ) { _ in
            onReady()
        }
    }

    func pendingInputRequestBackgroundSurfaceStart(forPanelId panelId: UUID) {
        guard let panel = panels[panelId] as? TerminalPanel else { return }
        panel.surface.requestBackgroundSurfaceStartIfNeeded()
    }
}


/// Lifted to `CmuxBrowser.ClosedBrowserPanelRestoreSnapshot` (Workspace
/// decomposition, Wave 3). This typealias keeps call sites byte-identical.
typealias ClosedBrowserPanelRestoreSnapshot = CmuxBrowser.ClosedBrowserPanelRestoreSnapshot

/// Workspace represents a sidebar tab.
/// Each workspace contains one BonsplitController that manages split panes and nested surfaces.
///
/// Observation: `Workspace` is `@MainActor @Observable`. SwiftUI views read it
/// directly (plain `var workspace: Workspace`, no `@ObservedObject`) and the
/// Observation runtime tracks the exact stored properties each `body` reads,
/// including the nested `@Observable` sub-models (`paneTree`, `surfaceRegistry`,
/// `unreadModel`). The legacy `objectWillChange.send()` forwards those sub-models
/// drove are no longer needed: a mutation to a tracked stored property (or to a
/// nested `@Observable`'s property a `body` read) invalidates the view by itself.
///
/// A handful of properties still feed Combine consumers that have not yet moved
/// to Observation (the sidebar fan-in `makeSidebarObservationPublisher`, the
/// mobile workspace-list observer, the per-workspace directory/remote readers).
/// Those consumers subscribed to the `@Published` `$projection`. Each such
/// property keeps a named `CurrentValueSubject` bridge (`titlePublisher`,
/// `currentDirectoryPublisher`, …) seeded at the end of `init` and fed from the
/// property's `didSet`, reproducing `Published.Publisher` semantics
/// (replay-on-subscribe, emit-on-every-set including equal values). The bridges
/// retire when those consumers migrate to `withObservationTracking`; this slice
/// only flips the class and keeps the Combine seam.
@MainActor
@Observable
final class Workspace: Identifiable, WorkspaceUnreadHosting, SurfaceMetadataHosting, WorkspaceTitleHosting, WorkspaceAppearanceHosting, SurfaceRegistryHosting, PendingTerminalInputHosting {
    /// The browser-panel creation policy now lives in `CmuxBrowser` as a
    /// top-level `Sendable` value. This nested typealias keeps the existing
    /// unqualified `BrowserPanelCreationPolicy` and `Workspace.BrowserPanelCreationPolicy`
    /// spellings byte-identical at every call site.
    typealias BrowserPanelCreationPolicy = CmuxBrowser.BrowserPanelCreationPolicy

    static let terminalScrollBarHiddenDidChangeNotification = Notification.Name(
        "cmux.workspaceTerminalScrollBarHiddenDidChange"
    )

    let id: UUID
    /// The injected app-level seam this workspace reaches for cross-window
    /// services it does not own (notification store, remote-tmux mirror
    /// controller, tab-manager resolution, focus log, and the app-level
    /// cloud-VM-create / move-to-new-workspace actions). Replaces the former
    /// direct `hostEnvironment?.X` reach-ups: every call site now routes
    /// through `self.hostEnvironment?.X`, so behavior is byte-identical (a nil
    /// `hostEnvironment` matches a nil `AppDelegate.shared`). Constructor-injected
    /// at the composition root; defaults to the running delegate so existing
    /// construction sites need no change.
    private let hostEnvironment: (any WorkspaceHostEnvironment)?
    /// When this workspace instance came into existence in this app session
    /// (creation, or restore at launch). The mobile list's last-activity
    /// fallback: a workspace that never fired a notification still carries a
    /// real timestamp instead of nothing.
    let createdAt = Date()
    var title: String {
        didSet { titlePublisher.send(title) }
    }
    var customTitle: String?
    /// Provenance of `customTitle`: `.user` for manual renames (sidebar,
    /// CLI, command palette), `.auto` for AI auto-naming. `nil` when no
    /// custom title is set. A present title with absent provenance is
    /// treated as `.user` so auto-naming never overwrites a title it
    /// cannot prove it owns.
    var customTitleSource: CustomTitleSource?
    var customDescription: String? {
        didSet { customDescriptionPublisher.send(customDescription) }
    }
    var isPinned: Bool = false {
        didSet { isPinnedPublisher.send(isPinned) }
    }
    /// Identifier of the WorkspaceGroup this workspace belongs to, or nil if ungrouped.
    /// The group entity itself lives in `TabManager.workspaceGroups`.
    var groupId: UUID? {
        didSet { groupIdPublisher.send(groupId) }
    }
    var customColor: String? {  // hex string, e.g. "#C0392B"
        didSet { customColorPublisher.send(customColor) }
    }
    /// User-defined environment variables applied to every shell spawned in this
    /// workspace: the initial terminal, every later pane/surface/split, and every
    /// surface recreated on session restore. Managed `CMUX_*` and terminal-identity
    /// variables always win — this dictionary is merged through the
    /// `additionalEnvironment` / `initialEnvironmentOverrides` channels, both of
    /// which skip `protectedStartupEnvironmentKeys` in
    /// `mergedStartupEnvironment(...)`, so a workspace env entry can never clobber
    /// the variables the daemon relies on (CMUX_WORKSPACE_ID, CMUX_SOCKET_PATH, …).
    /// Persisted in the session manifest and restored before surfaces are rebuilt.
    var workspaceEnvironment: [String: String] = [:]
    // Legacy in-memory state for old helpers/tests. Product UI, rendering, and
    // session persistence no longer honor per-workspace scrollbar overrides.
    private(set) var terminalScrollBarHidden: Bool = false
    var currentDirectory: String {
        didSet {
            // Combine bridge for the remaining `$currentDirectory` subscribers
            // (sidebar fan-in, mobile list observer, directory readers). Fires
            // on every set including equal values, matching `@Published`.
            currentDirectoryPublisher.send(currentDirectory)
            let oldDirectory = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let newDirectory = currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard oldDirectory != newDirectory else { return }
            scheduleExtensionSidebarProjectRootRefresh(for: currentDirectory)
            // Notify the sidebar so anchor-cwd-driven group config (color,
            // icon, context menu, newWorkspacePlacement) refreshes even
            // when the anchor isn't the visible/selected workspace. Group
            // headers are the anchor's only sidebar surface, so a
            // TabItemView-style observation isn't mounted for them.
            NotificationCenter.default.post(
                name: .workspaceCurrentDirectoryDidChange,
                object: self,
                userInfo: ["workspaceId": id]
            )
        }
    }
    private(set) var extensionSidebarProjectRootPath: String? {
        didSet { extensionSidebarProjectRootPathPublisher.send(extensionSidebarProjectRootPath) }
    }
    private var extensionSidebarProjectRootRefreshID: UInt64 = 0
    private(set) var surfaceTabBarDirectory: String? {
        didSet { surfaceTabBarDirectoryPublisher.send(surfaceTabBarDirectory) }
    }
    // `internal(set)` (was `private(set)`): the sole writer is the
    // `SurfaceLifecycleHosting` conformance in `Workspace+SurfaceLifecycleHosting.swift`,
    // which drives `SurfaceLifecycleCoordinator.setPreferredBrowserProfileID`. Still
    // module-internal, so external callers must go through `setPreferredBrowserProfileID`.
    internal(set) var preferredBrowserProfileID: UUID?

    /// Ordinal for CMUX_PORT range assignment (monotonically increasing per app session)
    var portOrdinal: Int = 0

    /// The bonsplit controller managing the split panes for this workspace
    let bonsplitController: BonsplitController

    /// How this workspace lays out its panels. Mutate through
    /// `setLayoutMode(_:)` (Workspace+CanvasLayout.swift) so canvas frames
    /// are seeded from the split layout on first entry.
    var layoutMode: WorkspaceLayoutMode = .splits

    /// Durable canvas-layout state (pane frames, z-order). Lives on the
    /// workspace so it survives canvas view remounts and workspace switches.
    let canvasModel = CanvasModel(metricsProvider: { CanvasLayoutSettings.currentMetrics() })
    private struct SurfaceTabBarExecutableButton {
        let button: CmuxSurfaceTabBarButton
        let builtInAction: CmuxSurfaceTabBarBuiltInAction?
        let workspaceCommand: CmuxResolvedCommand?
        let terminalCommandSourcePath: String?
    }

    private var surfaceTabBarCommandButtons: [String: SurfaceTabBarExecutableButton] = [:]
    private var surfaceTabBarButtonSourcePath: String?
    private var surfaceTabBarButtonGlobalConfigPath: String?

    /// The pane-tree sub-model (CmuxPanes): owns the panel registry, the
    /// surface-id mapping, and the pane-layout bookkeeping. The legacy
    /// accessors below forward here; `Workspace` hosts the property-observer
    /// hooks via `PaneTreeHosting`.
    let paneTree = PaneTreeModel<any Panel>()

    /// The surface-list derivation sub-model (CmuxWorkspaces): derives
    /// the ordered panel-id lists, focused panel, representative panel, per-pane
    /// selection, the `tabIdsTo*` pane queries, and the `paneLayoutVersion`
    /// reorder bump. `Workspace` is its tree-reading host via
    /// `WorkspaceSurfaceTreeReading`; the legacy accessors below forward here.
    let surfaceList = WorkspaceSurfaceListModel()

    /// The bonsplit tab context-menu coordinator (CmuxWorkspaces): owns the
    /// close-to-left/right/others slicing, the create-to-right index math, and
    /// the "Move Tab To…" destination encoding + routing. `Workspace` is its
    /// ``WorkspaceContextMenuHosting`` host (conformed in
    /// `Workspace+WorkspaceContextMenuHosting.swift`); the `splitTabBar`
    /// context-action dispatch and the move-destinations provider forward here.
    @ObservationIgnored
    private lazy var contextMenuCoordinator = WorkspaceContextMenuCoordinator(surfaceList: surfaceList)

    /// The per-workspace title sub-model (CmuxWorkspaces): owns the custom-title
    /// / custom-description state-transition logic, reaching the workspace's
    /// `@Published` title vocabulary through ``WorkspaceTitleHosting`` (which
    /// `Workspace` conforms). The methods below forward here byte-identically.
    let titleModel = WorkspaceTitleModel()

    /// The per-workspace appearance sub-model (CmuxWorkspaces): owns the custom
    /// tab-color and terminal-scrollbar state-transition logic, reaching the
    /// workspace's `@Published` appearance vocabulary (`customColor`,
    /// `terminalScrollBarHidden`) plus the two app-coupled effects
    /// (`WorkspaceTabColorSettings.normalizedHex`, the
    /// `terminalScrollBarHiddenDidChangeNotification` post) through
    /// ``WorkspaceAppearanceHosting`` (which `Workspace` conforms). The methods
    /// below forward here byte-identically.
    let appearanceModel = WorkspaceAppearanceModel()

    /// The surface-lifecycle coordinator (CmuxWorkspaces): owns the pane/index
    /// target resolvers over the live split tree (`paneId(forPanelId:)`,
    /// `indexInPane(forPanelId:)`, `preferredRightSideTargetPane`,
    /// `topRightBrowserReusePane`, `applyInitialSplitDividerPosition`). `Workspace`
    /// is its `SurfaceLifecycleHosting` host (see the conformance file); the
    /// legacy Panel-Operations accessors below forward here.
    let surfaceLifecycle = SurfaceLifecycleCoordinator()

    /// The cmux.json custom-layout coordinator (CmuxWorkspaces): owns the layout
    /// walk that builds the split tree, populates each leaf pane's surfaces,
    /// applies the configured divider positions, and focuses the marked surface.
    /// `Workspace` is its `WorkspaceLayoutHosting` host (see the conformance
    /// file); `applyCustomLayout` forwards here after mapping the app-target
    /// `CmuxLayoutNode` onto the package's `WorkspaceCustomLayoutNode` value.
    let layoutCoordinator = WorkspaceLayoutCoordinator()

    /// The surface-creation coordinator (CmuxWorkspaces): owns the value-typed
    /// resolution rules shared by the terminal-creation paths — the startup
    /// working-directory pick over an ordered candidate list, the inherited zoom
    /// font-point arithmetic, and the inheritance-config candidate walk, which it
    /// orchestrates back through ``SurfaceCreationHosting`` (conformed below). The
    /// legacy `resolvedTerminalStartupWorkingDirectory` /
    /// `normalizedTerminalWorkingDirectory` / `inheritedTerminalConfig` helpers
    /// forward here; `Workspace` still supplies the live reads and writes
    /// (candidate panels, Ghostty surface probes, lineage bookkeeping) through the
    /// seam because those require the live panel registry and the C bridge.
    let surfaceCreation = SurfaceCreationCoordinator()

    /// Routes external drag-and-drop onto the split layout (CmuxWorkspaces): the
    /// `handleExternalTabDrop` dispatch (session-index / file-preview drag →
    /// brand-new surface, otherwise a cross-window tab move) and the per-drop
    /// insert/split branching for the session and file paths. `Workspace`
    /// forwards `handleExternalTabDrop` / `handleFilePreviewDrop` /
    /// `handleExternalFileDrop` here and conforms to ``WorkspaceDropHosting``
    /// (witnessed in `Workspace+WorkspaceDropHosting.swift`) so registry
    /// consumption, surface creation, the live pane lookup, the cross-window
    /// move, and DEBUG tracing stay app-side. `attach(host: self)`-ed in `init`.
    let workspaceDrop = WorkspaceDropCoordinator<Workspace>()

    /// The package-pure open-or-focus reuse resolver (CmuxWorkspaces) the
    /// file-backed `openOrFocus…` entry points route their scan-and-route
    /// decision through; stateless and held so it is not re-instantiated per call.
    let surfaceReuseResolver = SurfaceReuseResolver()

    /// The session-restore coordinator (CmuxWorkspaces): owns the
    /// persisted-layout serialization bridge (live Bonsplit tree → persisted
    /// layout DTO and back to live divider positions). `Workspace` is its
    /// `WorkspaceSessionRestoreHosting` host; the session-snapshot/restore
    /// extension forwards `sessionLayoutSnapshot`/`applySessionDividerPositions`
    /// here. The richer snapshot/restore orchestration stays in the extension
    /// until its surface-creation substrate drains into this coordinator.
    let sessionRestoreCoordinator = SessionRestoreCoordinator<SessionWorkspaceLayoutSnapshot>()

    /// The surface-registry sub-model (CmuxWorkspaceCore): owns the
    /// per-surface registry annotations (tty names, shell-activity states,
    /// directories, titles, custom titles, listening ports) and the transient
    /// tab-selection/focus-reassert request state. The legacy accessors below
    /// forward here. The tty/shell/transient properties were not `@Published`;
    /// `panelDirectories`/`panelTitles`/`panelCustomTitles` were, so the model
    /// exposes per-field publishers surfaced through the internal
    /// `panel{Directories,Titles,CustomTitles}Publisher` forwarders below (the
    /// model itself stays `private` because its generic parameter
    /// `PendingTabSelectionRequest` is app-private).
    private let surfaceRegistry = SurfaceRegistryModel<PendingTabSelectionRequest>()

    /// The per-workspace surface-directory sub-model (CmuxWorkspaces): owns the
    /// directory-report and listening-port-fusion logic the legacy `Workspace`
    /// god object kept inline (`updatePanelDirectory`, `configTrackingDirectory`,
    /// `shouldIgnoreRestoredGuardedDirectoryReport`, `unmountedVolumeRoot`,
    /// `resolvedWorkingDirectory`, `recomputeListeningPorts`). It reads/writes
    /// `panelDirectories` / `surfaceListeningPorts` through the shared
    /// `surfaceRegistry`, and reaches the workspace's focus, `@Published`
    /// `currentDirectory` / `surfaceTabBarDirectory`, remote-mirror flag,
    /// requested-directory, restored-guarded-directory map, port sets, and
    /// fused `listeningPorts` through ``SurfaceMetadataHosting``, which
    /// `Workspace` conforms (see the conformance section). The methods below
    /// forward here so every call site stays byte-identical. It is `private`
    /// for the same reason `surfaceRegistry` is: its generic parameter
    /// `PendingTabSelectionRequest` is app-private.
    private let surfaceDirectoryMetadata: WorkspaceSurfaceMetadataModel<PendingTabSelectionRequest>

    /// Internal forwarders to the surface-registry directory/title publishers,
    /// read by the sidebar/mobile observation extensions in sibling files in
    /// place of the former `$panelDirectories`/`$panelTitles`/
    /// `$panelCustomTitles` projections. `surfaceRegistry` cannot itself be
    /// `internal` (its generic param is `private`), so the publishers are
    /// re-exposed here.
    var panelDirectoriesPublisher: AnyPublisher<[UUID: String], Never> {
        surfaceRegistry.panelDirectoriesPublisher
    }
    var panelTitlesPublisher: AnyPublisher<[UUID: String], Never> {
        surfaceRegistry.panelTitlesPublisher
    }
    var panelCustomTitlesPublisher: AnyPublisher<[UUID: String], Never> {
        surfaceRegistry.panelCustomTitlesPublisher
    }

    /// Internal forwarders to the surface-directory sub-model's conversation /
    /// submitted-message / fused-listening-port publishers, read by the sidebar
    /// observation extension in a sibling file in place of the former
    /// `$latestConversationMessage` / `$latestSubmittedMessage` /
    /// `$latestSubmittedAt` / `$listeningPorts` projections.
    /// `surfaceDirectoryMetadata` cannot itself be `internal` (its generic param
    /// is `private`), so the publishers are re-exposed here.
    var latestConversationMessagePublisher: AnyPublisher<String?, Never> {
        surfaceDirectoryMetadata.latestConversationMessagePublisher
    }
    var latestSubmittedMessagePublisher: AnyPublisher<String?, Never> {
        surfaceDirectoryMetadata.latestSubmittedMessagePublisher
    }
    var latestSubmittedAtPublisher: AnyPublisher<Date?, Never> {
        surfaceDirectoryMetadata.latestSubmittedAtPublisher
    }
    var listeningPortsPublisher: AnyPublisher<[Int], Never> {
        surfaceDirectoryMetadata.listeningPortsPublisher
    }

    /// The split-layout sub-model (CmuxPanes): owns the split/detach
    /// choreography bookkeeping (programmatic-split flag, detaching surface
    /// ids, captured transfer payloads, detach-close transaction count). The
    /// legacy accessors below forward here. None of the moved properties
    /// were `@Published`, so no observer hooks are required.
    private let splitLayout = SplitLayoutModel<DetachedSurfaceTransfer>()

    /// The split-lifecycle sub-model (CmuxPanes): owns the post-close
    /// bookkeeping (next-tab-to-select and split-zoom-clear decisions recorded
    /// against the pre-close tree). The `BonsplitDelegate` close methods below
    /// forward here. None of the moved properties were `@Published`, so no
    /// observer hooks are required.
    private let splitLifecycle = SplitLifecycleCoordinator()

    /// The split move/reorder coordinator (CmuxPanes): owns the surface
    /// move/reorder commands against the live split tree (move to a pane, move to
    /// the adjacent pane, reorder within a pane, realign remote-tmux mirror
    /// tabs). `Workspace` is its ``SplitMoveReorderHosting`` host (see the
    /// conformance file); the legacy Panel-Operations methods below forward here.
    let splitMoveReorder = SplitMoveReorderCoordinator()

    /// The split-close coordinator (CmuxPanes): owns the surface close commands
    /// against the live split tree (close a tab, optionally forcing; the same
    /// close with close-history recording). `Workspace` is its
    /// ``SplitCloseHosting`` host (conformed below); the `forceCloseTabIds`
    /// bypass set and close-history marks stay owned by `Workspace` because its
    /// `BonsplitDelegate` callbacks read them mid-close.
    private let splitClose = SplitCloseCoordinator()

    /// The split-detach coordinator (CmuxPanes): owns the surface detach command
    /// against the live split tree, driving every workspace-side effect through
    /// ``SplitDetachHosting`` (conformed below). Holds `splitLayout` for the
    /// detach-choreography state, so it is constructed in `init`. The legacy
    /// `detachSurface(panelId:)` method below forwards here.
    private let splitDetach: SplitDetachCoordinator<DetachedSurfaceTransfer>

    /// The surface-teardown coordinator (CmuxPanes): owns the whole-workspace
    /// teardown sequence that frees every panel's Ghostty surface before
    /// `TabManager` removes the workspace. `Workspace` is its
    /// ``SurfaceTeardownHosting`` host; `teardownAllPanels()` forwards here.
    private let surfaceTeardown = SurfaceTeardownCoordinator()

    /// Legacy Combine bridge for the remaining `workspace.$panels`
    /// subscribers. Driven exclusively from `panelsWillChange(to:)`, so it
    /// emits the new value during willSet and replays the current value on
    /// subscribe — the exact `Published.Publisher` semantics those call
    /// sites were written against. Single seam; delete when the subscribers
    /// move to @Observable observation.
    let panelsPublisher = CurrentValueSubject<[UUID: any Panel], Never>([:])
    /// Legacy Combine bridge for the remaining `$paneLayoutVersion`
    /// subscribers; same contract as `panelsPublisher`.
    let paneLayoutVersionPublisher = CurrentValueSubject<Int, Never>(0)

    // MARK: - Combine bridges for the not-yet-migrated `$property` subscribers
    //
    // `Workspace` is `@Observable`, so `@Published`'s `$projection` no longer
    // exists. The consumers that still read those projections — the sidebar
    // fan-in (`makeSidebarObservationPublisher` / `makeSidebarImmediateObservationPublisher`),
    // `MobileWorkspaceListObserver`, `AppSelectedWorkspaceDirectoryReadingAdapter`,
    // `RightSidebarToolPanel`, and `CmuxConfig`'s tracked-directory watcher —
    // read these named `CurrentValueSubject` bridges instead. Each bridge is
    // seeded at the end of `init` with the property's post-init value and fed
    // from the property's `didSet`, so it reproduces `Published.Publisher`
    // exactly: replay-on-subscribe plus an emission on every assignment,
    // including assignments of an equal value (`@Published` never compared).
    // Delete a bridge once its last `$`-style subscriber moves to
    // `withObservationTracking`.
    let titlePublisher = CurrentValueSubject<String, Never>("")
    let customDescriptionPublisher = CurrentValueSubject<String?, Never>(nil)
    let isPinnedPublisher = CurrentValueSubject<Bool, Never>(false)
    let customColorPublisher = CurrentValueSubject<String?, Never>(nil)
    let groupIdPublisher = CurrentValueSubject<UUID?, Never>(nil)
    let currentDirectoryPublisher = CurrentValueSubject<String, Never>("")
    let surfaceTabBarDirectoryPublisher = CurrentValueSubject<String?, Never>(nil)
    let extensionSidebarProjectRootPathPublisher = CurrentValueSubject<String?, Never>(nil)
    let remoteConfigurationPublisher = CurrentValueSubject<WorkspaceRemoteConfiguration?, Never>(nil)
    let remoteConnectionStatePublisher = CurrentValueSubject<WorkspaceRemoteConnectionState, Never>(.disconnected)
    let remoteConnectionDetailPublisher = CurrentValueSubject<String?, Never>(nil)
    let remoteDaemonStatusPublisher = CurrentValueSubject<WorkspaceRemoteDaemonStatus, Never>(WorkspaceRemoteDaemonStatus())
    let activeRemoteTerminalSessionCountPublisher = CurrentValueSubject<Int, Never>(0)

    /// Mapping from bonsplit TabID to our Panel instances
    var panels: [UUID: any Panel] {
        get { paneTree.panels }
        set { paneTree.panels = newValue }
    }

    /// Monotonic counter bumped only when the spatial (left-to-right, top-to-bottom)
    /// order of panels changes without the panel *set* changing — i.e. a pure
    /// drag-reorder of tabs within or across panes. Membership changes already
    /// fire `$panels`; pure reorders mutate only `bonsplitController` state, which
    /// is not `@Published`, so observers (e.g. the mobile workspace-list observer)
    /// would otherwise never learn about a reorder. We gate the bump on an actual
    /// change of `orderedPanelIds` so that divider drags and selection-only events
    /// (which also flow through `didChangeGeometry`) do not fire `objectWillChange`.
    var paneLayoutVersion: Int {
        get { paneTree.paneLayoutVersion }
        set { paneTree.paneLayoutVersion = newValue }
    }

    /// Subscriptions for panel updates (e.g., browser title changes)
    var panelSubscriptions: [UUID: AnyCancellable] = [:]
    private var agentSessionPanelCallbackIds: Set<UUID> = []

    /// When true, suppresses auto-creation in didSplitPane (programmatic splits handle their own panels);
    /// stored in the split-layout sub-model.
    private var isProgrammaticSplit: Bool {
        get { splitLayout.isProgrammaticSplit }
        set { splitLayout.isProgrammaticSplit = newValue }
    }
    private var debugStressPreloadSelectionDepth = 0

    /// Last terminal panel used as an inheritance source (typically last focused terminal).
    var lastTerminalConfigInheritancePanelId: UUID?
    /// Last known terminal font points from inheritance sources. Used as fallback when
    /// no live terminal surface is currently available.
    private var lastTerminalConfigInheritanceFontPoints: Float?
    /// Per-panel inherited zoom lineage. Descendants reuse this root value unless
    /// a panel is explicitly re-zoomed by the user.
    var terminalInheritanceFontPointsByPanelId: [UUID: Float] = [:]

    /// Callback used by TabManager to capture recently closed browser panels for Cmd+Shift+T restore.
    var onClosedBrowserPanel: ((ClosedBrowserPanelRestoreSnapshot) -> Void)?
    weak var owningTabManager: TabManager?

    // Closing tabs mutates split layout immediately; terminal views handle their own AppKit
    // layout/size synchronization.

    /// The currently focused pane's panel ID. Forwards to
    /// ``WorkspaceSurfaceListModel/focusedPanelId``.
    var focusedPanelId: UUID? {
        surfaceList.focusedPanelId
    }

    /// Panel ids in bonsplit's spatial order: depth-first over the split tree
    /// (left/top child before right/bottom child), and within each pane in tab
    /// order. This is the on-screen left-to-right, top-to-bottom ordering and is
    /// the single source of truth for serializing panels (e.g. the mobile
    /// terminal list) and for detecting reorders. Any panels not currently in
    /// bonsplit are appended in a stable id order so the list never drops a panel.
    /// Forwards to ``WorkspaceSurfaceListModel/orderedPanelIds``.
    var orderedPanelIds: [UUID] {
        surfaceList.orderedPanelIds
    }

    /// The currently focused terminal panel (if any)
    var focusedTerminalPanel: TerminalPanel? {
        guard let panelId = focusedPanelId,
              let panel = panels[panelId] as? TerminalPanel else {
            return nil
        }
        return panel
    }

    /// Forwards to
    /// ``WorkspaceSurfaceListModel/representativePanelIdForWorkspaceManualUnread()``.
    func representativePanelIdForWorkspaceManualUnread() -> UUID? {
        surfaceList.representativePanelIdForWorkspaceManualUnread()
    }

    /// Forwards to
    /// ``WorkspaceSurfaceListModel/effectiveSelectedPanelId(inPaneId:)``.
    func effectiveSelectedPanelId(inPane paneId: PaneID) -> UUID? {
        surfaceList.effectiveSelectedPanelId(inPaneId: paneId.id)
    }

    /// Working directory for each panel; stored in the surface-registry
    /// sub-model. The former `$panelDirectories` Combine subscribers read
    /// `surfaceRegistry.panelDirectoriesPublisher` instead.
    var panelDirectories: [UUID: String] {
        get { surfaceRegistry.panelDirectories }
        set { surfaceRegistry.panelDirectories = newValue }
    }
    /// Auto-derived (non-custom) title for each panel; stored in the
    /// surface-registry sub-model. The former `$panelTitles` Combine
    /// subscribers read `surfaceRegistry.panelTitlesPublisher` instead.
    var panelTitles: [UUID: String] {
        get { surfaceRegistry.panelTitles }
        set { surfaceRegistry.panelTitles = newValue }
    }
    /// User/system custom title override for each panel; stored in the
    /// surface-registry sub-model. The former `$panelCustomTitles` Combine
    /// subscribers read `surfaceRegistry.panelCustomTitlesPublisher` instead.
    var panelCustomTitles: [UUID: String] {
        get { surfaceRegistry.panelCustomTitles }
        set { surfaceRegistry.panelCustomTitles = newValue }
    }
    /// Provenance of entries in `panelCustomTitles` (see ``CustomTitleSource``);
    /// stored in the surface-registry sub-model. An entry may be absent for a
    /// title carried across panel moves or restored from older snapshots; absent
    /// provenance is treated as `.user`.
    var panelCustomTitleSources: [UUID: CustomTitleSource] {
        get { surfaceRegistry.panelCustomTitleSources }
        set { surfaceRegistry.panelCustomTitleSources = newValue }
    }
    /// The user's pinned panels; stored in the surface-registry sub-model. The
    /// legacy property was `@Published` (no `$pinnedPanelIds` subscriber); the
    /// model fires `willChange` (wired in `init` to `objectWillChange.send()`)
    /// at `willSet` time to preserve the SwiftUI re-render moment for the
    /// `ContentView` reader of `workspace.pinnedPanelIds`.
    var pinnedPanelIds: Set<UUID> {
        get { surfaceRegistry.pinnedPanelIds }
        set { surfaceRegistry.pinnedPanelIds = newValue }
    }
    /// The per-workspace unread / attention-indicator sub-model (CmuxNotifications):
    /// owns the unread state the legacy `Workspace` god object kept as loose
    /// `@Published` stored properties (`manualUnreadPanelIds`,
    /// `restoredUnreadPanelIndicators`, `manualUnreadMarkedAt`) plus the badge-sync
    /// and indicator state-transition logic. The legacy accessors and methods below
    /// forward here. Those properties were `@Published` and SwiftUI views observed
    /// them on this `ObservableObject`, so the model fires `willChange` (wired in
    /// `init` to `objectWillChange.send()`) at `willSet` time to preserve the
    /// `@Published` emission moment. `Workspace` conforms to
    /// `WorkspaceUnreadHosting` for the live panel / bonsplit / notification-store
    /// reads the transitions need.
    let unreadModel = WorkspaceUnreadModel()
    var manualUnreadPanelIds: Set<UUID> {
        get { unreadModel.manualUnreadPanelIds }
        set { unreadModel.manualUnreadPanelIds = newValue }
    }
    private var restoredUnreadPanelIndicators: [UUID: RestoredPanelUnreadIndicator] {
        get { unreadModel.restoredUnreadPanelIndicators }
        set { unreadModel.restoredUnreadPanelIndicators = newValue }
    }
    var restoredUnreadPanelIds: Set<UUID> {
        unreadModel.restoredUnreadPanelIds
    }
    private(set) var tmuxLayoutSnapshot: LayoutSnapshot?
    /// The tmux workspace-pane overlay flash mirrors now live on
    /// ``unreadModel``; these forward its `@Observable` reads so the existing
    /// `ContentView` accessors stay byte-identical. The model fires `willChange`
    /// (`objectWillChange.send()`) on each write, preserving the former
    /// `@Published private(set)` emission moment.
    var tmuxWorkspaceFlashPanelId: UUID? { unreadModel.tmuxWorkspaceFlashPanelId }
    var tmuxWorkspaceFlashReason: WorkspaceAttentionFlashReason? { unreadModel.tmuxWorkspaceFlashReason }
    var tmuxWorkspaceFlashToken: UInt64 { unreadModel.tmuxWorkspaceFlashToken }
    var manualUnreadMarkedAt: [UUID: Date] {
        get { unreadModel.manualUnreadMarkedAt }
        set { unreadModel.manualUnreadMarkedAt = newValue }
    }
    /// The sidebar-metadata sub-model (CmuxSidebar): owns the
    /// sidebar status entries, metadata blocks, log entries, progress, and
    /// git-branch / pull-request presentation state. The legacy accessors below
    /// forward here. The moved properties were `@Published` and fed the sidebar
    /// observation publishers, so the model exposes per-field Combine publishers
    /// (`statusEntriesPublisher` etc.) that `makeSidebarObservationPublisher()`
    /// subscribes to in place of the former `$projection`s, preserving the
    /// debounced refresh timing byte-identically.
    let sidebarMetadata = WorkspaceSidebarMetadataModel(
        limitProvider: WorkspaceSidebarLogEntryLimitProvider()
    )
    var statusEntries: [String: SidebarStatusEntry] {
        get { sidebarMetadata.statusEntries }
        set { sidebarMetadata.statusEntries = newValue }
    }
    var metadataBlocks: [String: SidebarMetadataBlock] {
        get { sidebarMetadata.metadataBlocks }
        set { sidebarMetadata.metadataBlocks = newValue }
    }
    /// The latest assistant/conversation message preview; stored in the
    /// surface-directory sub-model. The former `$latestConversationMessage`
    /// Combine subscriber reads
    /// `surfaceDirectoryMetadata.latestConversationMessagePublisher` instead.
    /// `private(set)` is preserved: only the model's record paths (driven via
    /// the workspace forwards) mutate it.
    private(set) var latestConversationMessage: String? {
        get { surfaceDirectoryMetadata.latestConversationMessage }
        set { surfaceDirectoryMetadata.latestConversationMessage = newValue }
    }
    /// The latest submitted-prompt preview; stored in the surface-directory
    /// sub-model. The former `$latestSubmittedMessage` Combine subscriber reads
    /// `surfaceDirectoryMetadata.latestSubmittedMessagePublisher` instead.
    private(set) var latestSubmittedMessage: String? {
        get { surfaceDirectoryMetadata.latestSubmittedMessage }
        set { surfaceDirectoryMetadata.latestSubmittedMessage = newValue }
    }
    /// The timestamp of the latest submitted prompt; stored in the
    /// surface-directory sub-model. The former `$latestSubmittedAt` Combine
    /// subscriber reads `surfaceDirectoryMetadata.latestSubmittedAtPublisher`
    /// instead.
    private(set) var latestSubmittedAt: Date? {
        get { surfaceDirectoryMetadata.latestSubmittedAt }
        set { surfaceDirectoryMetadata.latestSubmittedAt = newValue }
    }
    var logEntries: [SidebarLogEntry] {
        get { sidebarMetadata.logEntries }
        set { sidebarMetadata.logEntries = newValue }
    }
    var progress: SidebarProgressState? {
        get { sidebarMetadata.progress }
        set { sidebarMetadata.progress = newValue }
    }
    var gitBranch: SidebarGitBranchState? {
        get { sidebarMetadata.gitBranch }
        set { sidebarMetadata.gitBranch = newValue }
    }
    var panelGitBranches: [UUID: SidebarGitBranchState] {
        get { sidebarMetadata.panelGitBranches }
        set { sidebarMetadata.panelGitBranches = newValue }
    }
    var pullRequest: SidebarPullRequestState? {
        get { sidebarMetadata.pullRequest }
        set { sidebarMetadata.pullRequest = newValue }
    }
    var panelPullRequests: [UUID: SidebarPullRequestState] {
        get { sidebarMetadata.panelPullRequests }
        set { sidebarMetadata.panelPullRequests = newValue }
    }
    /// Discovered listening ports per surface; stored in the surface-registry
    /// sub-model. This map had no Combine `$` subscriber, so the move carries
    /// no observer-parity bridge.
    var surfaceListeningPorts: [UUID: [Int]] {
        get { surfaceRegistry.surfaceListeningPorts }
        set { surfaceRegistry.surfaceListeningPorts = newValue }
    }
    var agentListeningPorts: [Int] = []
    var remoteConfiguration: WorkspaceRemoteConfiguration? {
        didSet { remoteConfigurationPublisher.send(remoteConfiguration) }
    }
    var remoteConnectionState: WorkspaceRemoteConnectionState = .disconnected {
        didSet { remoteConnectionStatePublisher.send(remoteConnectionState) }
    }
    var remoteConnectionDetail: String? {
        didSet { remoteConnectionDetailPublisher.send(remoteConnectionDetail) }
    }
    var remoteDaemonStatus: WorkspaceRemoteDaemonStatus = WorkspaceRemoteDaemonStatus() {
        didSet { remoteDaemonStatusPublisher.send(remoteDaemonStatus) }
    }
    var remoteDetectedPorts: [Int] = []
    var remoteForwardedPorts: [Int] = []
    var remotePortConflicts: [Int] = []
    var remoteProxyEndpoint: BrowserProxyEndpoint?
    var remoteHeartbeatCount: Int = 0
    var remoteLastHeartbeatAt: Date?
    /// The fused, sorted, deduplicated workspace listening-port projection;
    /// stored in the surface-directory sub-model. The former `$listeningPorts`
    /// Combine subscriber reads
    /// `surfaceDirectoryMetadata.listeningPortsPublisher` instead.
    var listeningPorts: [Int] {
        get { surfaceDirectoryMetadata.listeningPorts }
        set { surfaceDirectoryMetadata.listeningPorts = newValue }
    }
    private(set) var activeRemoteTerminalSessionCount: Int = 0 {
        didSet { activeRemoteTerminalSessionCountPublisher.send(activeRemoteTerminalSessionCount) }
    }
    /// The controlling-terminal device name per panel id; stored in the
    /// surface-registry sub-model.
    var surfaceTTYNames: [UUID: String] {
        get { surfaceRegistry.surfaceTTYNames }
        set { surfaceRegistry.surfaceTTYNames = newValue }
    }
    // Internal (not private) so the `Workspace+RemoteSurfaceHosting.swift`
    // witness can resolve the active session coordinator for the lifted
    // remote-PTY/port-scan/upload commands.
    var remoteSessionController: RemoteSessionCoordinator?
    /// Orchestrates the workspace-facing remote *surface* commands (remote PTY
    /// bridge list/start/resize/detach, remote port-scan kick/sync/enablement,
    /// dropped-file upload) and the child-exit surface-tracking predicates.
    /// Lifted to `CmuxRemoteSession`; the workspace forwards each former inline
    /// method to this coordinator and conforms to `RemoteSurfaceHosting`
    /// (witnessed in `Workspace+RemoteSurfaceHosting.swift`) for the small slice
    /// of live state those bodies read. Held by `Workspace`, references the host
    /// weakly, so there is no retain cycle.
    let remoteSurfaceCoordinator = RemoteSurfaceCoordinator<Workspace>()

    /// Orchestrates closing one pane of a mirrored multi-pane tmux window (the
    /// pane-header ✕): the close-tab warning decision, the live pane-activity
    /// query, the in-flight guard set, and the kill-pane dispatch. `Workspace`
    /// forwards `requestRemoteTmuxPaneClose(windowMirror:tmuxPaneId:)` to this
    /// coordinator and conforms to `RemoteTmuxMirrorHosting` (witnessed below)
    /// for the one app-target decision the orchestration cannot make on its own,
    /// presenting the confirmation modal. Held by `Workspace`, references the
    /// host weakly, so there is no retain cycle.
    let remoteTmuxMirrorCoordinator = RemoteTmuxMirrorCoordinator<Workspace>()
    private var pendingRemoteForegroundAuthToken: String?
    var activeRemoteSessionControllerID: UUID?
    private var remoteLastErrorFingerprint: String?
    private var remoteLastDaemonErrorFingerprint: String?
    private var remoteLastPortConflictFingerprint: String?
    private var remoteDetectedSurfaceIds: Set<UUID> = []
    // Internal (not private) so the `Workspace+RemoteSurfaceHosting.swift`
    // witness can read these surface-tracking sets for the lifted predicates.
    var activeRemoteTerminalSurfaceIds: Set<UUID> = []
    var endedPersistentRemotePTYAttachSurfaceIds: Set<UUID> = []
    /// Owns the reverse-CLI-relay workspace/surface ID alias maps and the
    /// per-panel remote-PTY session-id store, plus the snapshot/attach-match
    /// session-id derivations. `Workspace` holds it, attaches itself as the live
    /// host (`Workspace+RemoteRelaySessionHosting.swift`), and forwards every
    /// alias/session-id call here. Lives in `CmuxRemoteWorkspace`.
    let remoteRelaySession = RemoteRelaySessionCoordinator<Workspace>()
    private var suppressRemoteTerminalStartupForSessionRestoreScaffold = false
    var pendingRemoteTerminalChildExitSurfaceIds: Set<UUID> = []

    /// Display target and reconnect command for the remote terminal that just disconnected.
    /// Set right before `createReplacementTerminalPanel()` so the replacement terminal stays
    /// visibly disconnected instead of falling through to a local login shell.
    /// The value type lives in `CmuxRemoteWorkspace`
    /// (`PendingRemoteDisconnectReplacement`).
    private var pendingRemoteDisconnectReplacement: PendingRemoteDisconnectReplacement?
    var remoteDisconnectPlaceholderPanelIds: Set<UUID> = []

    private static let remoteErrorStatusKey = "remote.error"
    private static let remotePortConflictStatusKey = "remote.port_conflicts"
    private static let remoteNotificationCooldown: TimeInterval = 5 * 60
    /// Forwards to ``SSHControlMasterCleanupService/runCommandOverrideForTesting``.
    /// The cleanup spawn queue and `Process` lifecycle now live in that service
    /// (`CmuxRemoteWorkspace`); this computed shim preserves the process-wide
    /// `Workspace.runSSHControlMasterCommandOverrideForTesting` test seam used by
    /// `WorkspaceRemoteConnectionTests`.
    nonisolated static var runSSHControlMasterCommandOverrideForTesting: (([String]) -> Void)? {
        get { SSHControlMasterCleanupService.runCommandOverrideForTesting }
        set { SSHControlMasterCleanupService.runCommandOverrideForTesting = newValue }
    }
#if DEBUG
    /// XCTest seam: assign before `configureRemoteConnection` to script the
    /// session coordinator's subprocess results. Instance-scoped injection of
    /// the package process-runner seam (replaces the legacy process-wide
    /// `WorkspaceRemoteSessionController.runProcessOverrideForTesting` static).
    var remoteSessionProcessRunnerOverrideForTesting: (any RemoteSessionProcessRunning)?
#endif
    /// The shell-activity classification per panel id; stored in the
    /// surface-registry sub-model.
    var panelShellActivityStates: [UUID: PanelShellActivityState] {
        get { surfaceRegistry.panelShellActivityStates }
        set { surfaceRegistry.panelShellActivityStates = newValue }
    }
    /// Agent lifecycle / hibernation / resume-binding per-panel state, owned by the
    /// `CMUXAgentLaunch` model. The workspace forwards its former stored properties to this
    /// instance's dictionaries so external readers stay byte-identical (the established
    /// `panelShellActivityStates`-via-`surfaceRegistry` forwarding pattern).
    let agentHibernation = AgentHibernationLifecycleModel<
        SessionRestorableAgentSnapshot,
        SurfaceResumeBindingSnapshot,
        AgentHibernationLifecycleState
    >()

    /// Resume-progression state for a restored agent snapshot. Lifted to `CMUXAgentLaunch`; kept
    /// as a typealias so existing `RestoredAgentResumeState` references stay byte-identical.
    typealias RestoredAgentResumeState = AgentHibernationLifecycleModel<
        SessionRestorableAgentSnapshot,
        SurfaceResumeBindingSnapshot,
        AgentHibernationLifecycleState
    >.RestoredAgentResumeState

    /// Orchestrates the agent lifecycle / hibernation / resume-binding flows over the shared
    /// `agentHibernation` state model. Lifted to `CMUXAgentLaunch`; the workspace forwards each
    /// former inline method to this coordinator and conforms to `AgentHibernationHosting` (the live
    /// seam the orchestration reaches back through, witnessed in
    /// `Workspace+AgentHibernationHosting.swift`). Constructed over `agentHibernation` and
    /// `attach(host: self)`-ed in `init`.
    let agentHibernationCoordinator: AgentHibernationCoordinator<
        Workspace,
        AgentHibernationLifecycleState
    >

    /// Orchestrates the agent-conversation fork flows (split, new tab, new
    /// workspace, the resolved new-workspace launch descriptor, the right-click
    /// context-action dispatch, and the menu availability check). Lifted to
    /// `CMUXAgentLaunch`; the workspace forwards each former inline fork method to
    /// this coordinator and conforms to `AgentForkHosting` (the live seam the
    /// orchestration reaches back through, witnessed in
    /// `Workspace+AgentForkHosting.swift`). `attach(host: self)`-ed in `init`.
    let agentForkCoordinator = AgentForkCoordinator<Workspace>()

    /// PIDs associated with agent status entries (e.g. claude_code), keyed by status key.
    /// Used for stale-session detection: if the PID is dead, the status entry is cleared.
    var agentPIDs: [String: pid_t] {
        get { agentHibernation.agentPIDs }
        set { agentHibernation.agentPIDs = newValue }
    }
    var agentPIDPanelIdsByKey: [String: UUID] {
        get { agentHibernation.agentPIDPanelIdsByKey }
        set { agentHibernation.agentPIDPanelIdsByKey = newValue }
    }
    var agentPIDKeysByPanelId: [UUID: Set<String>] {
        get { agentHibernation.agentPIDKeysByPanelId }
        set { agentHibernation.agentPIDKeysByPanelId = newValue }
    }
    var agentLifecycleStatesByPanelId: [UUID: [String: AgentHibernationLifecycleState]] {
        get { agentHibernation.agentLifecycleStatesByPanelId }
        set { agentHibernation.agentLifecycleStatesByPanelId = newValue }
    }
    var restoredTerminalScrollbackByPanelId: [UUID: String] = [:]
#if DEBUG
    var debugSessionSnapshotScrollbackFallbackPanelIds: Set<UUID> = []
    var debugSessionSnapshotSyntheticScrollbackByPanelId: [UUID: String] = [:]
#endif
    var restoredAgentSnapshotsByPanelId: [UUID: SessionRestorableAgentSnapshot] {
        get { agentHibernation.restoredAgentSnapshotsByPanelId }
        set { agentHibernation.restoredAgentSnapshotsByPanelId = newValue }
    }
    var surfaceResumeBindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot] {
        get { agentHibernation.surfaceResumeBindingsByPanelId }
        set { agentHibernation.surfaceResumeBindingsByPanelId = newValue }
    }
    private var restoredGuardedWorkingDirectoriesByPanelId: [UUID: String] = [:]
    var restoredAgentResumeStatesByPanelId: [UUID: RestoredAgentResumeState] {
        get { agentHibernation.restoredAgentResumeStatesByPanelId }
        set { agentHibernation.restoredAgentResumeStatesByPanelId = newValue }
    }
    var invalidatedRestoredAgentFingerprintsByPanelId: [UUID: Int] {
        get { agentHibernation.invalidatedRestoredAgentFingerprintsByPanelId }
        set { agentHibernation.invalidatedRestoredAgentFingerprintsByPanelId = newValue }
    }
    /// Queues terminal input until a panel's surface shell is ready
    /// (CmuxWorkspaces). Owns the pending surface-ready registration registry and
    /// its bookkeeping; `Workspace` is its ``PendingTerminalInputHosting`` host
    /// (conformed below) and supplies the live panel/surface reads, `sendInput`,
    /// and the `.terminalSurfaceDidBecomeReady` observer. The custom-layout
    /// startup-command send reaches it through `layoutSendStartupCommand`.
    let pendingTerminalInput = PendingTerminalInputCoordinator()
    private let sessionRestorePolicy: WorkspaceSessionRestorePolicyService<SurfaceResumeBindingSnapshot>

    typealias SurfaceResumeStartupLaunch = WorkspaceSurfaceResumeStartupLaunch

    // Sidebar rows cache snapshots, so observation must begin with the current
    // workspace state. Build state publishers from the current values of the
    // `$property` Combine bridges instead of dropping the first value and
    // repairing timing with a Void event.
    @ObservationIgnored
    lazy var sidebarImmediateObservationPublisher: AnyPublisher<Void, Never> = makeSidebarImmediateObservationPublisher()
    @ObservationIgnored
    lazy var sidebarObservationPublisher: AnyPublisher<Void, Never> = makeSidebarObservationPublisher()

    private func scheduleExtensionSidebarProjectRootRefresh(for directory: String) {
        extensionSidebarProjectRootRefreshID &+= 1
        let refreshID = extensionSidebarProjectRootRefreshID
        let trimmedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDirectory.isEmpty else {
            extensionSidebarProjectRootPath = nil
            return
        }

        Task.detached(priority: .utility) { [weak self, trimmedDirectory, refreshID] in
            let projectRootPath = Self.extensionSidebarProjectRootPath(onDiskFor: trimmedDirectory)
            await MainActor.run { [weak self] in
                guard let self,
                      self.extensionSidebarProjectRootRefreshID == refreshID else {
                    return
                }
                self.extensionSidebarProjectRootPath = projectRootPath
            }
        }
    }

    nonisolated private static func extensionSidebarProjectRootPath(onDiskFor directory: String) -> String? {
        var url = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        let fileManager = FileManager.default
        while url.path != "/" {
            if fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private var preservesProxyFailureWhileSSHTerminalIsAlive: Bool {
        RemoteProxyFailurePolicy().preservesProxyFailureWhileSSHTerminalIsAlive(
            transport: remoteConfiguration?.transport,
            activeSessionCount: activeRemoteTerminalSessionCount,
            startupCommand: remoteConfiguration?.terminalStartupCommand
        )
    }

    private var hasProxyOnlyRemoteSidebarError: Bool {
        RemoteSidebarErrorClassifier().isProxyOnly(
            statusEntryValue: statusEntries[Self.remoteErrorStatusKey]?.value
        )
    }

    private func remoteNotificationCooldownKey(target: String) -> String? {
        RemoteNotificationCooldownKey().key(
            destination: remoteConfiguration?.destination,
            target: target
        )
    }

    var focusedSurfaceId: UUID? { focusedPanelId }
    var surfaceDirectories: [UUID: String] {
        get { panelDirectories }
        set { panelDirectories = newValue }
    }

    private var processTitle: String

    nonisolated static func resolveCloseConfirmation(
        shellActivityState: PanelShellActivityState?,
        fallbackNeedsConfirmClose: Bool
    ) -> Bool {
        switch shellActivityState ?? .unknown {
        case .promptIdle:
            return false
        case .commandRunning:
            return true
        case .unknown:
            return fallbackNeedsConfirmClose
        }
    }

    nonisolated private static func makeSessionRestorePolicyService(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> WorkspaceSessionRestorePolicyService<SurfaceResumeBindingSnapshot> {
        WorkspaceSessionRestorePolicyService(
            applyStoredApproval: { binding, fileURL, signingSecret in
                SurfaceResumeApprovalStore(
                    fileURL: fileURL,
                    signingSecret: signingSecret
                ).applyingStoredApproval(to: binding)
            },
            shouldRunPromptedSurfaceResume: { binding in
                Self.shouldRunPromptedSurfaceResume(binding)
            },
            isRunningUnderAutomatedTests: {
                SessionRestorePolicy().isRunningUnderAutomatedTests
            },
            truncateScrollback: { text in
                ScrollbackTruncation().truncated(text)
            },
            hermesCodexEnvironment: WorkspaceHermesCodexEnvironment(
                customBaseURLEnvironmentKey: HermesAgentCodexEnvironment.customBaseURLEnvironmentKey,
                defaultProvider: HermesAgentCodexEnvironment.defaultProvider,
                codexResponsesAPIMode: HermesAgentCodexEnvironment.codexResponsesAPIMode,
                applyingDefaultCodexBaseURL: { environment in
                    HermesAgentCodexEnvironment.applyingDefaultCodexBaseURL(to: environment)
                },
                resolvingDefaultCodexModel: { environment in
                    HermesAgentCodexEnvironment.defaultCodexModel(environment: environment)
                }
            ),
            temporaryDirectory: temporaryDirectory
        )
    }

    nonisolated private static func shouldRunPromptedSurfaceResume(_ binding: SurfaceResumeBindingSnapshot) -> Bool {
        guard Thread.isMainThread, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return false
        }
        return MainActor.assumeIsolated {
            shouldRunPromptedSurfaceResumeOnMain(binding)
        }
    }

    @MainActor
    private static func shouldRunPromptedSurfaceResumeOnMain(_ binding: SurfaceResumeBindingSnapshot) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "surfaceResumeApproval.runPrompt.title",
            defaultValue: "Run Resume Command?"
        )
        alert.informativeText = String(
            format: String(
                localized: "surfaceResumeApproval.runPrompt.message",
                defaultValue: "cmux is restoring a terminal with this resume command:\n\n%@\n\nWorking directory: %@"
            ),
            binding.command,
            binding.cwd ?? String(localized: "surfaceResumeApproval.cwd.none", defaultValue: "None")
        )
        alert.addButton(withTitle: String(localized: "surfaceResumeApproval.runPrompt.run", defaultValue: "Run"))
        alert.addButton(withTitle: String(localized: "surfaceResumeApproval.runPrompt.skip", defaultValue: "Skip"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Initialization

    private static func currentSplitButtonTooltips() -> BonsplitConfiguration.SplitButtonTooltips {
        BonsplitConfiguration.SplitButtonTooltips(
            newTerminal: KeyboardShortcutSettings.Action.newSurface.tooltip("New Terminal"),
            newBrowser: KeyboardShortcutSettings.Action.openBrowser.tooltip("New Browser"),
            splitRight: KeyboardShortcutSettings.Action.splitRight.tooltip("Split Right"),
            splitDown: KeyboardShortcutSettings.Action.splitDown.tooltip("Split Down")
        )
    }

    private static func bonsplitAppearance(from config: GhosttyConfig) -> BonsplitConfiguration.Appearance {
        bonsplitAppearance(
            from: config.backgroundColor,
            backgroundOpacity: config.backgroundOpacity,
            tabTitleFontSize: config.surfaceTabBarFontSize
        )
    }

    nonisolated static func usesSharedSurfaceBackdrop(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "sidebarMatchTerminalBackground")
    }

    private static func bonsplitAppearance(
        from backgroundColor: NSColor,
        backgroundOpacity: Double,
        tabTitleFontSize: CGFloat = 11
    ) -> BonsplitConfiguration.Appearance {
        let chromeColorResolver = BonsplitChromeColorResolver()
        let sharesWindowBackdrop = chromeColorResolver.usesWindowRootTerminalBackdrop()
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
        )
        let chromeColors = chromeColorResolver.bonsplitChromeColors(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            renderingMode: renderingMode
        )
        return BonsplitConfiguration.Appearance(
            tabBarHeight: WindowChromeMetrics.bonsplitTabBarHeight,
            tabTitleFontSize: tabTitleFontSize,
            splitButtonBackdropEffect: Self.bonsplitSplitButtonBackdropEffect(),
            splitButtonTooltips: Self.currentSplitButtonTooltips(),
            enableAnimations: false,
            chromeColors: chromeColors,
            usesSharedBackdrop: sharesWindowBackdrop
        )
    }

    func applyGhosttyChrome(from config: GhosttyConfig, reason: String = "unspecified") {
        let chromeColorResolver = BonsplitChromeColorResolver()
        let sharesWindowBackdrop = chromeColorResolver.usesWindowRootTerminalBackdrop()
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
        )
        let nextChromeColors = chromeColorResolver.bonsplitChromeColors(
            backgroundColor: config.backgroundColor,
            backgroundOpacity: config.backgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            renderingMode: renderingMode
        )
        let nextTabTitleFontSize = config.surfaceTabBarFontSize
        let currentAppearance = bonsplitController.configuration.appearance
        let currentTabTitleFontSize = currentAppearance.tabTitleFontSize
        let colorsChanged = !chromeColorResolver.bonsplitChromeColorsEqual(
            currentAppearance.chromeColors,
            nextChromeColors
        )
        let sharedBackdropChanged = currentAppearance.usesSharedBackdrop != sharesWindowBackdrop
        let fontSizeChanged = abs(currentTabTitleFontSize - nextTabTitleFontSize) > 0.0001
        let isNoOp = !colorsChanged && !sharedBackdropChanged && !fontSizeChanged

        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme apply workspace=\(id.uuidString) reason=\(reason) " +
                "current=[\(chromeColorResolver.bonsplitChromeColorsLogDescription(currentAppearance.chromeColors))] " +
                "next=[\(chromeColorResolver.bonsplitChromeColorsLogDescription(nextChromeColors))] " +
                "currentTabFont=\(String(format: "%.3f", currentTabTitleFontSize)) " +
                "nextTabFont=\(String(format: "%.3f", nextTabTitleFontSize)) " +
                "sharesWindowBackdrop=\(sharesWindowBackdrop ? 1 : 0) " +
                "currentUsesSharedBackdrop=\(currentAppearance.usesSharedBackdrop ? 1 : 0) " +
                "paneBackdrop=\(chromeColorResolver.usesBonsplitPaneTerminalBackdrop(renderingMode: renderingMode, sharesWindowBackdrop: sharesWindowBackdrop) ? 1 : 0) " +
                "noop=\(isNoOp)"
            )
        }

        guard !isNoOp else { return }

        if colorsChanged {
            bonsplitController.configuration.appearance.chromeColors = nextChromeColors
        }
        if sharedBackdropChanged {
            bonsplitController.configuration.appearance.usesSharedBackdrop = sharesWindowBackdrop
        }
        if fontSizeChanged {
            bonsplitController.configuration.appearance.tabTitleFontSize = nextTabTitleFontSize
        }

        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme applied workspace=\(id.uuidString) reason=\(reason) " +
                "resulting=[\(chromeColorResolver.bonsplitChromeColorsLogDescription(bonsplitController.configuration.appearance.chromeColors))] " +
                "resultingUsesSharedBackdrop=\(bonsplitController.configuration.appearance.usesSharedBackdrop ? 1 : 0) " +
                "resultingTabFont=\(String(format: "%.3f", bonsplitController.configuration.appearance.tabTitleFontSize))"
            )
        }
    }

    func applyGhosttyChrome(backgroundColor: NSColor, backgroundOpacity: Double, reason: String = "unspecified") {
        let chromeColorResolver = BonsplitChromeColorResolver()
        let sharesWindowBackdrop = chromeColorResolver.usesWindowRootTerminalBackdrop()
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
        )
        let nextChromeColors = chromeColorResolver.bonsplitChromeColors(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            renderingMode: renderingMode
        )
        let currentChromeColors = bonsplitController.configuration.appearance.chromeColors
        let currentUsesSharedBackdrop = bonsplitController.configuration.appearance.usesSharedBackdrop
        let colorsChanged = !chromeColorResolver.bonsplitChromeColorsEqual(currentChromeColors, nextChromeColors)
        let sharedBackdropChanged = currentUsesSharedBackdrop != sharesWindowBackdrop
        let isNoOp = !colorsChanged && !sharedBackdropChanged

        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme apply workspace=\(id.uuidString) reason=\(reason) " +
                "current=[\(chromeColorResolver.bonsplitChromeColorsLogDescription(currentChromeColors))] " +
                "next=[\(chromeColorResolver.bonsplitChromeColorsLogDescription(nextChromeColors))] " +
                "sharesWindowBackdrop=\(sharesWindowBackdrop ? 1 : 0) " +
                "currentUsesSharedBackdrop=\(currentUsesSharedBackdrop ? 1 : 0) " +
                "paneBackdrop=\(chromeColorResolver.usesBonsplitPaneTerminalBackdrop(renderingMode: renderingMode, sharesWindowBackdrop: sharesWindowBackdrop) ? 1 : 0) " +
                "noop=\(isNoOp)"
            )
        }

        if isNoOp {
            return
        }
        if colorsChanged {
            bonsplitController.configuration.appearance.chromeColors = nextChromeColors
        }
        if sharedBackdropChanged {
            bonsplitController.configuration.appearance.usesSharedBackdrop = sharesWindowBackdrop
        }
        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme applied workspace=\(id.uuidString) reason=\(reason) " +
                "resulting=[\(chromeColorResolver.bonsplitChromeColorsLogDescription(bonsplitController.configuration.appearance.chromeColors))] " +
                "resultingUsesSharedBackdrop=\(bonsplitController.configuration.appearance.usesSharedBackdrop ? 1 : 0)"
            )
        }
    }

    init(
        title: String = "Terminal",
        workingDirectory: String? = nil,
        portOrdinal: Int = 0,
        configTemplate: CmuxSurfaceConfigTemplate? = nil,
        initialSurface: NewWorkspaceInitialSurface = .terminal,
        initialTerminalCommand: String? = nil,
        initialTerminalInput: String? = nil,
        initialTerminalEnvironment: [String: String] = [:],
        workspaceEnvironment: [String: String] = [:],
        initialDetachedSurface: DetachedSurfaceTransfer? = nil,
        sessionRestorePolicy: WorkspaceSessionRestorePolicyService<SurfaceResumeBindingSnapshot>? = nil,
        hostEnvironment: (any WorkspaceHostEnvironment)? = AppDelegate.shared
    ) {
        self.id = UUID()
        self.hostEnvironment = hostEnvironment
        self.sessionRestorePolicy = sessionRestorePolicy ?? Self.makeSessionRestorePolicyService()
        let sanitizedWorkspaceEnvironment = Self.sanitizedWorkspaceEnvironment(workspaceEnvironment)
        self.workspaceEnvironment = sanitizedWorkspaceEnvironment
        self.portOrdinal = portOrdinal
        self.processTitle = title
        self.title = title
        self.customTitle = nil
        self.customTitleSource = nil
        self.customDescription = nil

        let trimmedWorkingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasWorkingDirectory = !trimmedWorkingDirectory.isEmpty
        let initialDirectory = hasWorkingDirectory
            ? trimmedWorkingDirectory
            : FileManager.default.homeDirectoryForCurrentUser.path
        self.currentDirectory = hasWorkingDirectory
            ? trimmedWorkingDirectory
            : FileManager.default.homeDirectoryForCurrentUser.path
        self.surfaceTabBarDirectory = initialDirectory

        // Configure bonsplit with keepAllAlive to preserve terminal state
        // and keep split entry instantaneous.
        // Use the cached Ghostty config so new workspaces inherit tab-strip sizing
        // without paying repeated parse costs on the workspace-creation hot path.
        let initialSurfaceTabBarFontSize = GhosttyConfig.load().surfaceTabBarFontSize
        let appearance = Self.bonsplitAppearance(
            from: GhosttyApp.shared.defaultBackgroundColor,
            backgroundOpacity: GhosttyApp.shared.defaultBackgroundOpacity,
            tabTitleFontSize: initialSurfaceTabBarFontSize
        )
        let config = BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: !CloseTabWarningStore(defaults: .standard).hidesTabCloseButton,
            allowCloseLastPane: false,
            allowTabReordering: true,
            allowCrossPaneTabMove: true,
            autoCloseEmptyPanes: true,
            contentViewLifecycle: .keepAllAlive,
            newTabPosition: .current,
            appearance: appearance
        )
        self.bonsplitController = BonsplitController(configuration: config)
        self.surfaceDirectoryMetadata = WorkspaceSurfaceMetadataModel(registry: surfaceRegistry)
        self.splitDetach = SplitDetachCoordinator(splitLayout: splitLayout)
        self.agentHibernationCoordinator = AgentHibernationCoordinator(model: agentHibernation)
        agentHibernationCoordinator.attach(host: self)
        agentForkCoordinator.attach(host: self)
        workspaceDrop.attach(host: self)
        remoteSurfaceCoordinator.attach(host: self)
        remoteTmuxMirrorCoordinator.attach(host: self)
        remoteRelaySession.attach(host: self)
        paneTree.attach(host: self)
        surfaceList.attach(tree: self)
        surfaceLifecycle.attach(host: self)
        layoutCoordinator.attach(host: self)
        pendingTerminalInput.attach(host: self)
        layoutFollowUpCoordinator.attach(host: self)
        splitMoveReorder.attach(host: self)
        splitClose.attach(host: self)
        splitDetach.attach(host: self)
        surfaceTeardown.attach(host: self)
        closedBrowserRestoreStaging.attach(host: self)
        sessionRestoreCoordinator.attach(host: self)
        unreadModel.attach(host: self)
        // `unreadModel`/`surfaceRegistry` are themselves `@Observable`. With
        // `Workspace` now `@Observable`, a SwiftUI `body` that reads
        // `workspace.unreadModel.x` registers Observation on that property
        // directly, so the legacy `willChange -> objectWillChange.send()`
        // forwards (which existed only to invalidate `@ObservedObject`
        // observers of the `ObservableObject` owner) are no longer needed.
        surfaceRegistry.attach(host: self)
        surfaceDirectoryMetadata.attach(host: self)
        titleModel.attach(host: self)
        appearanceModel.attach(host: self)
        contextMenuCoordinator.attach(host: self)
        bonsplitController.contextMenuShortcuts = TabContextAction.contextMenuShortcuts()

        // Remove the default "Welcome" tab that bonsplit creates
        let welcomeTabIds = bonsplitController.allTabIds

        // When the workspace boots with an explicit initial command (`cmux ssh` /
        // `cmux vm new` both funnel their ssh startup script through this path),
        // hold the PTY open after that command exits. Without this Ghostty
        // silently respawns a local login shell and the user can't tell a dead
        // VM apart from a healthy local prompt.
        var resolvedConfigTemplate = configTemplate
        if let trimmedCommand = initialTerminalCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedCommand.isEmpty {
            var template = resolvedConfigTemplate ?? CmuxSurfaceConfigTemplate()
            template.waitAfterCommand = true
            resolvedConfigTemplate = template
        }

        var initialTabId: TabID?
        if let initialDetachedSurface {
            if let initialPaneId = bonsplitController.allPaneIds.first,
               attachDetachedSurface(initialDetachedSurface, inPane: initialPaneId, focus: false) != nil {
                initialTabId = surfaceIdFromPanelId(initialDetachedSurface.panelId)
            }
        } else if initialSurface == .browser {
            // Create the initial browser panel in its default new-tab state.
            // Mirrors the minimal terminal branch below plus the browser panel
            // wiring `attachDetachedSurface` performs for reattached panels.
            let browserPanel = BrowserPanel(
                workspaceId: id,
                profileID: resolvedNewBrowserProfileID()
            )
            configureBrowserPanel(browserPanel)
            panels[browserPanel.id] = browserPanel
            panelTitles[browserPanel.id] = browserPanel.displayTitle
            // Land the first activation in the address bar so a URL can be
            // typed immediately; BrowserPanelView consumes the pending request
            // when the surface first appears.
            _ = browserPanel.requestAddressBarFocus(selectionIntent: .selectAll)

            if let tabId = bonsplitController.createTab(
                title: browserPanel.displayTitle,
                icon: browserPanel.displayIcon,
                kind: SurfaceKind.browser.rawValue,
                isDirty: browserPanel.isDirty,
                isLoading: browserPanel.isLoading,
                isAudioMuted: browserPanel.isMuted,
                isPinned: false
            ) {
                surfaceIdToPanelId[tabId] = browserPanel.id
                initialTabId = tabId
            }
            installBrowserPanelSubscription(browserPanel)
        } else {
            // Create initial terminal panel
            let terminalPanel = TerminalPanel(
                workspaceId: id,
                context: GHOSTTY_SURFACE_CONTEXT_TAB,
                configTemplate: resolvedConfigTemplate,
                workingDirectory: hasWorkingDirectory ? trimmedWorkingDirectory : nil,
                portOrdinal: portOrdinal,
                initialCommand: initialTerminalCommand,
                initialInput: initialTerminalInput,
                initialEnvironmentOverrides: Self.startupEnvironment(
                    workspaceEnvironment: sanitizedWorkspaceEnvironment,
                    overlaying: initialTerminalEnvironment
                )
            )
            configureNewTerminalPanel(terminalPanel)
            panels[terminalPanel.id] = terminalPanel
            panelTitles[terminalPanel.id] = terminalPanel.displayTitle
            seedTerminalInheritanceFontPoints(panelId: terminalPanel.id, configTemplate: configTemplate)

            // Create initial tab in bonsplit and store the mapping
            if let tabId = bonsplitController.createTab(
                title: title,
                icon: "terminal.fill",
                kind: SurfaceKind.terminal.rawValue,
                isDirty: false,
                isPinned: false
            ) {
                surfaceIdToPanelId[tabId] = terminalPanel.id
                initialTabId = tabId
            }
        }

        // Close the default Welcome tab(s)
        for welcomeTabId in welcomeTabIds {
            bonsplitController.closeTab(welcomeTabId)
        }

        bonsplitController.onExternalTabDrop = { [weak self] request in
            self?.handleExternalTabDrop(request) ?? false
        }
        bonsplitController.onExternalFileDrop = { [weak self] request in
            self?.handleExternalFileDrop(request) ?? false
        }
        bonsplitController.tabContextMoveDestinationsProvider = { [weak self] tabId, _ in
            self?.contextMenuMoveDestinations(for: tabId) ?? []
        }
        bonsplitController.tabContextForkConversationAvailabilityProvider = { [weak self] tabId, _ in
            guard let self,
                  let panelId = self.panelIdFromSurfaceId(tabId) else { return false }
            return self.canForkAgentConversationFromPanel(panelId)
        }
        bonsplitController.tabContextForkConversationDefaultActionProvider = { _, _ in
            AgentConversationForkDestination.configuredDefault().tabContextAction
        }
        bonsplitController.onTabCloseRequest = { [weak self] tabId, _, source in
            switch source {
            case .closeButton:
                self?.markTabCloseButtonClose(surfaceId: tabId)
            case .middleClick:
                self?.markExplicitClose(surfaceId: tabId)
            }
        }
        bonsplitController.onTabZoomToggleRequest = { [weak self] tabId, _ in
            guard let self,
                  let panelId = self.panelIdFromSurfaceId(tabId) else { return false }
            return self.toggleSplitZoom(panelId: panelId)
        }

        // Set ourselves as delegate
        bonsplitController.delegate = self

        // Ensure bonsplit has a focused pane and our didSelectTab handler runs for the
        // initial terminal. bonsplit's createTab selects internally but does not emit
        // didSelectTab, and focusedPaneId can otherwise be nil until user interaction.
        if let initialTabId, initialDetachedSurface == nil {
            // Focus the pane containing the initial tab (or the first pane as fallback).
            let paneToFocus: PaneID? = {
                for paneId in bonsplitController.allPaneIds {
                    if bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == initialTabId }) {
                        return paneId
                    }
                }
                return bonsplitController.allPaneIds.first
            }()
            if let paneToFocus {
                bonsplitController.focusPane(paneToFocus)
            }
            bonsplitController.selectTab(initialTabId)
        }
        tmuxLayoutSnapshot = bonsplitController.layoutSnapshot()
        scheduleExtensionSidebarProjectRootRefresh(for: currentDirectory)

        // Forward shared agent-index refreshes by bumping an Observation-tracked
        // revision so the bonsplit tab-bar re-evaluates Fork Conversation
        // availability the moment a background refresh lands. `WorkspaceContentView`
        // reads `liveAgentIndexRevision` in its `body`, so Observation re-renders
        // it on each bump. `SharedLiveAgentIndex` is now `@Observable`, so this is a
        // self-renewing `withObservationTracking` over its `index` /
        // `processDetectedIndex`, the direct `@Observable` replacement for the former
        // `SharedLiveAgentIndex -> self.objectWillChange` Combine forward.
        observeSharedLiveAgentIndex()

        // Seed the `$property` Combine bridges with their post-init values.
        // `didSet` does not fire for assignments inside `init`, so a subscriber
        // attaching later (every bridge consumer attaches after construction)
        // must still replay the workspace's real current value, exactly as
        // `@Published`'s publisher replayed its current value on subscribe.
        titlePublisher.send(title)
        customDescriptionPublisher.send(customDescription)
        isPinnedPublisher.send(isPinned)
        customColorPublisher.send(customColor)
        groupIdPublisher.send(groupId)
        currentDirectoryPublisher.send(currentDirectory)
        surfaceTabBarDirectoryPublisher.send(surfaceTabBarDirectory)
        extensionSidebarProjectRootPathPublisher.send(extensionSidebarProjectRootPath)
        remoteConfigurationPublisher.send(remoteConfiguration)
        remoteConnectionStatePublisher.send(remoteConnectionState)
        remoteConnectionDetailPublisher.send(remoteConnectionDetail)
        remoteDaemonStatusPublisher.send(remoteDaemonStatus)
        activeRemoteTerminalSessionCountPublisher.send(activeRemoteTerminalSessionCount)
    }

    /// Bumped whenever `SharedLiveAgentIndex` reports a background refresh.
    /// `WorkspaceContentView` reads this in its `body` so Observation re-renders
    /// the bonsplit tab-bar (which re-evaluates Fork Conversation availability)
    /// the moment the shared index reloads. Replaces the former
    /// `objectWillChange.send()` forward.
    private(set) var liveAgentIndexRevision: Int = 0

    /// Self-renewing `withObservationTracking` registration over the shared
    /// agent-index's `@Observable` snapshots. `withObservationTracking` is
    /// one-shot, so the `onChange` re-registers (deferred to the next main-actor
    /// turn, after the mutation completes) to keep tracking subsequent reloads.
    /// `[weak self]` plus the `guard let self` lets the loop terminate when the
    /// workspace deinits. A bump may land one main-hop after the change versus the
    /// former synchronous Combine `objectWillChange`; the counter only drives a
    /// re-render, so the deferral is observationally equivalent.
    private func observeSharedLiveAgentIndex() {
        withObservationTracking {
            _ = SharedLiveAgentIndex.shared.index
            _ = SharedLiveAgentIndex.shared.processDetectedIndex
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.liveAgentIndexRevision &+= 1
                self.observeSharedLiveAgentIndex()
            }
        }
    }

    // `isolated deinit` keeps teardown on the MainActor. As a plain
    // `@MainActor ObservableObject` the deinit was implicitly MainActor-isolated;
    // the `@Observable` macro rewrites the stored properties into accessors whose
    // isolation would otherwise force a `nonisolated` deinit, which cannot touch
    // this MainActor state or call the `@MainActor` `RemoteSessionCoordinator.stop()`.
    // Isolating the deinit preserves the exact prior teardown semantics.
    isolated deinit {
        pendingTerminalInput.removeAllObserverTokens()
        activeRemoteSessionControllerID = nil
        remoteSessionController?.stop()
    }

    func refreshSplitButtonTooltips() {
        let tooltips = Self.currentSplitButtonTooltips()
        var configuration = bonsplitController.configuration
        guard configuration.appearance.splitButtonTooltips != tooltips else { return }
        configuration.appearance.splitButtonTooltips = tooltips
        bonsplitController.configuration = configuration
    }

    func refreshSplitButtonBackdropEffect() {
        var configuration = bonsplitController.configuration
        configuration.appearance.splitButtonBackdropEffect = Self.bonsplitSplitButtonBackdropEffect()
        bonsplitController.configuration = configuration
    }

    func refreshTabCloseButtonVisibility() {
        let allowCloseTabs = !CloseTabWarningStore(defaults: .standard).hidesTabCloseButton
        var configuration = bonsplitController.configuration
        guard configuration.allowCloseTabs != allowCloseTabs else { return }
        configuration.allowCloseTabs = allowCloseTabs
        bonsplitController.configuration = configuration
    }

    func applySurfaceTabBarButtons(
        _ buttons: [CmuxSurfaceTabBarButton],
        sourcePath: String?,
        globalConfigPath: String,
        terminalCommandSourcePaths: [String: String],
        workspaceCommands: [String: CmuxResolvedCommand]
    ) {
        let executableButtons = Dictionary(
            uniqueKeysWithValues: buttons.compactMap { button in
                if button.terminalCommand != nil {
                    return (
                        button.id,
                        SurfaceTabBarExecutableButton(
                            button: button,
                            builtInAction: nil,
                            workspaceCommand: nil,
                            terminalCommandSourcePath: button.actionSourcePath ?? terminalCommandSourcePaths[button.id]
                        )
                    )
                }
                if let workspaceCommand = workspaceCommands[button.id] {
                    return (
                        button.id,
                        SurfaceTabBarExecutableButton(
                            button: button,
                            builtInAction: nil,
                            workspaceCommand: workspaceCommand,
                            terminalCommandSourcePath: nil
                        )
                    )
                }
                if case .builtIn(let builtInAction) = button.action,
                   builtInAction.bonsplitAction == nil {
                    return (
                        button.id,
                        SurfaceTabBarExecutableButton(
                            button: button,
                            builtInAction: builtInAction,
                            workspaceCommand: nil,
                            terminalCommandSourcePath: nil
                        )
                    )
                }
                return nil
            }
        )
        surfaceTabBarCommandButtons = executableButtons
        surfaceTabBarButtonSourcePath = sourcePath
        surfaceTabBarButtonGlobalConfigPath = globalConfigPath

        let bonsplitButtons = buttons.map { button in
            let executable = executableButtons[button.id]
            let allowProjectLocalIcon = executable.map {
                CmuxConfigExecutor.isTrustedSurfaceButton(
                    $0.button,
                    workspaceCommand: $0.workspaceCommand,
                    terminalCommandSourcePath: $0.terminalCommandSourcePath,
                    surfaceTabBarConfigSourcePath: sourcePath,
                    globalConfigPath: globalConfigPath
                )
            } ?? true
            return button.bonsplitActionButton(
                configSourcePath: sourcePath,
                globalConfigPath: globalConfigPath,
                allowProjectLocalIcon: allowProjectLocalIcon
            )
        }
        var configuration = bonsplitController.configuration
        guard configuration.appearance.splitButtons != bonsplitButtons else { return }
        configuration.appearance.splitButtons = bonsplitButtons
        bonsplitController.configuration = configuration
    }

    // MARK: - Surface ID to Panel ID Mapping

    /// Mapping from bonsplit TabID (surface ID) to panel UUID
    /// Mapping from bonsplit TabID (surface id) to the owning panel id;
    /// stored in the pane-tree sub-model.
    var surfaceIdToPanelId: [TabID: UUID] {
        get { paneTree.surfaceIdToPanelId }
        set { paneTree.surfaceIdToPanelId = newValue }
    }

    /// Tab IDs that are allowed to close even if they would normally require confirmation.
    /// This is used by app-level confirmation prompts (for example, Close Tab) so the
    /// Bonsplit delegate doesn't block the close after the user already confirmed.
    private var forceCloseTabIds: Set<TabID> = []

    /// Tab IDs that are currently showing (or about to show) a close confirmation prompt.
    /// Prevents repeated close gestures (e.g., middle-click spam) from stacking dialogs.
    private var pendingCloseConfirmTabIds: Set<TabID> = []

    // `internal` (not `private`) so the `Workspace+ClosedBrowserRestoreStagingHosting`
    // sibling extension can read it as the `stagingSuppressClosedPanelHistory`
    // witness; every other access stays within this file.
    var suppressClosedPanelHistory = false

    /// Pane-close panel ids now live on `splitLifecycle.pendingPaneClosePanelIds`;
    /// this map stays here because it holds the app-target `ClosedPanelHistoryEntry`.
    private var pendingPaneCloseHistoryEntries: [UUID: [ClosedPanelHistoryEntry]] = [:]
    /// Stages recently-closed browser restore snapshots for `Cmd+Shift+T`. Owns
    /// the per-tab pending map and the snapshot-build decision (lifted to
    /// `CmuxBrowser.ClosedBrowserRestoreStaging`); this workspace conforms to
    /// ``ClosedBrowserRestoreStagingHosting`` and the coordinator reads the live
    /// Bonsplit/panel state through it.
    let closedBrowserRestoreStaging = ClosedBrowserRestoreStaging()
    /// Re-entrancy guard for the tab-selection apply loop; stored in the
    /// surface-registry sub-model.
    private var isApplyingTabSelection: Bool {
        get { surfaceRegistry.isApplyingTabSelection }
        set { surfaceRegistry.isApplyingTabSelection = newValue }
    }
    /// The pending tab-selection request payload. Stays app-side (it carries
    /// AppKit hosted-view references); the surface-registry sub-model stores
    /// it opaquely as its `TabSelectionRequest` generic binding.
    private struct PendingTabSelectionRequest {
        let tabId: TabID
        let pane: PaneID
        let reassertAppKitFocus: Bool
        let focusIntent: PanelFocusIntent?
        let resumeHibernatedAgent: Bool?
        let previousTerminalHostedView: GhosttySurfaceScrollView?
    }
    /// The coalesced pending tab-selection request; stored in the
    /// surface-registry sub-model.
    private var pendingTabSelection: PendingTabSelectionRequest? {
        get { surfaceRegistry.pendingTabSelection }
        set { surfaceRegistry.pendingTabSelection = newValue }
    }
    private var isReconcilingFocusState = false
    private var focusReconcileScheduled = false
#if DEBUG
    private(set) var debugFocusReconcileScheduledDuringDetachCount: Int = 0
    private var debugLastDidMoveTabTimestamp: TimeInterval = 0
    private var debugDidMoveTabEventCount: UInt64 = 0
#endif
    /// Owns the event-driven layout-follow-up state machine (the pending
    /// reason/focus/browser-panel ids, the needs-geometry flag, the attempt
    /// version + stall count, the reparent-focus suppression set, the
    /// `portalRenderingEnabled` flag, and the Clock-driven retry/timeout). The
    /// portal show/hide + geometry reconcile primitives stay app-side: this
    /// `Workspace` is the coordinator's ``WorkspaceLayoutFollowUpHosting`` (see
    /// `Workspace+WorkspaceLayoutFollowUpHosting.swift`).
    let layoutFollowUpCoordinator: WorkspaceLayoutFollowUpCoordinator = {
#if DEBUG
        return WorkspaceLayoutFollowUpCoordinator(debugLog: { cmuxDebugLog($0) })
#else
        return WorkspaceLayoutFollowUpCoordinator()
#endif
    }()
    // `internal` (not `private`): also read by the `AgentHibernationHosting`
    // conformance in `Workspace+AgentHibernationHosting.swift`.
    var agentHibernationAutoResumePresentationVisible = true
    // The non-focusing-split focus-reassert state (the pending request and the
    // monotonic generation counter) lives in `surfaceRegistry`
    // (`SurfaceRegistryModel`), which also owns the reassert state-machine
    // methods (`beginNonFocusSplitFocusReassert` / `matches…` / `clear…` /
    // `markExplicitFocusIntent`). The `Workspace` `BonsplitDelegate` methods
    // forward into it, so no app-side accessor mirror is needed.

    /// Captured detach transfer payloads; stored in the split-layout
    /// sub-model. Mutations go through the model's detach-choreography
    /// verbs; this read-only view feeds the empty/count checks.
    private var pendingDetachedSurfaces: [TabID: DetachedSurfaceTransfer] {
        splitLayout.pendingDetachedSurfaces
    }
    /// Open detach-close transaction count; stored in the split-layout
    /// sub-model, mutated through its transaction verbs.
    private var activeDetachCloseTransactions: Int {
        splitLayout.activeDetachCloseTransactions
    }
    // Internal (not private) so the `Workspace+RemoteSurfaceHosting.swift`
    // witness can read the detach-close flag for the session-ended predicate.
    var isDetachingCloseTransaction: Bool { splitLayout.isDetachingCloseTransaction }
    /// True while ``reorderRemoteTmuxMirrorTabs(toPanelOrder:)`` is rearranging tabs.
    /// bonsplit's `reorderTab`/`selectTab`/`focusPane` fire `didSelectTab` /
    /// `didFocusPane`, each of which runs the full `applyTabSelection` activation
    /// (focus moves, hibernation resume, focus-LRU record). A reactive tmux-driven
    /// reorder must not run any of that because the user's selection/focus is unchanged.
    var isApplyingRemoteTmuxTabReorder = false
    private var pendingRemoteSurfaceTTYName: String?
    private var pendingRemoteSurfaceTTYSurfaceId: UUID?
    private var pendingRemoteSurfacePortKickReason: PortScanKickReason?
    private var pendingRemoteSurfacePortKickSurfaceId: UUID?
    // When the last live remote terminal is detached out, the source workspace may be
    // closed immediately after the move succeeds. That teardown must not shut down the
    // shared SSH control master that is still serving the moved terminal.
    private var skipControlMasterCleanupAfterDetachedRemoteTransfer = false
    var transferredRemoteCleanupConfigurationsByPanelId: [UUID: WorkspaceRemoteConfiguration] = [:]

    /// Source panel + pane captured at the start of a ``SplitDetachCoordinator``
    /// detach turn, before the bonsplit close removes the panel from `panels`, so
    /// the surface-closed publish can still pass the real panel (legacy
    /// `detachSurface` captured `sourcePanel`/`sourcePaneId` into locals before
    /// closing). One slot is safe: a detach turn is fully synchronous (no awaits,
    /// no nested detach).
    private var detachSourceCapture: (panelId: UUID, panel: any Panel, paneId: PaneID?)?

#if DEBUG
    /// Relaxed from `private` to `internal` so the lifted drop-routing seam
    /// conformance (`Workspace+WorkspaceDropHosting.swift`) can format the
    /// `split.externalDrop.end` elapsed time; the body is unchanged.
    func debugElapsedMs(since start: TimeInterval) -> String {
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return String(format: "%.2f", ms)
    }
#endif

    func panelIdFromSurfaceId(_ surfaceId: TabID) -> UUID? {
        paneTree.panelId(forSurfaceId: surfaceId)
    }

    func markExplicitClose(surfaceId: TabID) {
        surfaceRegistry.markExplicitClose(surfaceId: surfaceId, panelId: panelIdFromSurfaceId(surfaceId))
    }

    func markCloseHistoryEligible(panelId: UUID) {
        surfaceRegistry.markCloseHistoryEligible(panelId: panelId, surfaceId: surfaceIdFromPanelId(panelId))
    }

    @discardableResult
    func requestCloseTabRecordingHistory(_ tabId: TabID, force: Bool) -> Bool {
        splitClose.requestCloseTabRecordingHistory(tabId, force: force)
    }

    /// Non-interactive socket/API close path. Remote-tmux mirror tabs must be
    /// routed to tmux before a local forced close is attempted; otherwise
    /// `forceCloseTabIds` bypasses `shouldCloseTab` and removes the cmux tab
    /// while leaving the remote tmux window alive.
    @discardableResult
    func requestNonInteractiveCloseTabRecordingHistory(_ tabId: TabID) -> Bool {
        switch routeRemoteTmuxNonInteractiveTabCloseIfNeeded(tabId) {
        case .routed:
            return true
        case .rejectedMirrorTab:
            return false
        case .notMirrorTab:
            return requestCloseTabRecordingHistory(tabId, force: true)
        }
    }

    func routeRemoteTmuxNonInteractiveTabCloseIfNeeded(_ tabId: TabID) -> WorkspaceRemoteTmuxNonInteractiveCloseRoute {
        guard isRemoteTmuxMirror,
              let panelId = panelIdFromSurfaceId(tabId),
              let remoteTmuxController = hostEnvironment?.remoteTmuxController,
              remoteTmuxController.isMirrorWindowTab(workspaceId: id, panelId: panelId)
        else {
            return .notMirrorTab
        }
        return remoteTmuxController.handleMirrorTabCloseRequested(workspaceId: id, panelId: panelId)
            ? .routed
            : .rejectedMirrorTab
    }

    /// Closes the surface identified by `surfaceId`, recording it in close
    /// history. If the surface maps to a tab, routes through the tab-close path
    /// (non-interactive when `force`); otherwise marks the panel close-history
    /// eligible and closes the panel directly.
    ///
    /// Single source of truth for the socket control plane's "close one surface
    /// recording history" behavior: the `surface.close`, `surface.action close`,
    /// `sidebar.tab close`, and `browser.tab close` witnesses all call this, as
    /// did the former `TerminalController.closeSurfaceRecordingHistory(in:…)` and
    /// its two byte-identical conformance twins.
    @discardableResult
    func closeSurfaceRecordingHistory(surfaceId: UUID, force: Bool) -> Bool {
        if let tabId = surfaceIdFromPanelId(surfaceId) {
            if force {
                return requestNonInteractiveCloseTabRecordingHistory(tabId)
            }
            return requestCloseTabRecordingHistory(tabId, force: force)
        }

        markCloseHistoryEligible(panelId: surfaceId)
        return closePanel(surfaceId, force: force)
    }

    func withClosedPanelHistorySuppressed(_ body: () -> Void) {
        let previous = suppressClosedPanelHistory
        suppressClosedPanelHistory = true
        defer { suppressClosedPanelHistory = previous }
        body()
    }

    func markTabCloseButtonClose(surfaceId: TabID) {
        surfaceRegistry.markTabCloseButtonClose(surfaceId: surfaceId)
    }

    func surfaceIdFromPanelId(_ panelId: UUID) -> TabID? {
        paneTree.surfaceId(forPanelId: panelId)
    }

    private func configureNewTerminalPanel(_ terminalPanel: TerminalPanel) {
        // Record the workspace env this freshly-created panel inherited, so a later
        // respawn (which reuses this panel even after a move to another workspace)
        // can drop it and re-apply the current workspace's env instead of leaking
        // the source workspace's (#5995). Only creation runs through here — attach
        // uses configureTerminalPanel — so it keeps reflecting the workspace the
        // surface's env was built from until the panel is respawned.
        terminalPanel.seededWorkspaceEnvironment = workspaceEnvironment
        if TerminalTextBoxInputSettings.focusOnNewTerminals() {
            terminalPanel.preferTextBoxInputWhenActivated()
        } else if TerminalTextBoxInputSettings.showOnNewTerminals() {
            terminalPanel.showTextBoxInputWhenAvailable()
        }
        configureTerminalPanel(terminalPanel)
    }

    private func configureTerminalPanel(_ terminalPanel: TerminalPanel) {
        terminalPanel.onRequestWorkspacePaneFlash = { [weak self, weak terminalPanel] reason in
            guard let self, let terminalPanel else { return }
            self.triggerWorkspacePaneFlash(panelId: terminalPanel.id, reason: reason)
        }
        terminalPanel.onRequestAgentHibernationResume = { [weak self, weak terminalPanel] focus in
            guard let self, let terminalPanel else { return false }
            return self.resumeAgentHibernation(panelId: terminalPanel.id, focus: focus)
        }
    }

    private func configureBrowserPanel(_ browserPanel: BrowserPanel) {
        browserPanel.webViewDidRequestClose = { [weak self, weak browserPanel] in
            guard let self, let browserPanel else { return }
            guard self.panels[browserPanel.id] is BrowserPanel else { return }
#if DEBUG
            cmuxDebugLog(
                "browser.close.requestedByPage ws=\(self.id.uuidString.prefix(5)) " +
                "panel=\(browserPanel.id.uuidString.prefix(5))"
            )
#endif
            _ = self.closePanel(browserPanel.id, force: true)
        }
    }

    private func triggerWorkspacePaneFlash(panelId: UUID, reason: WorkspaceAttentionFlashReason) {
        unreadModel.triggerWorkspacePaneFlash(panelId: panelId, reason: reason)
    }

    private func installBrowserPanelSubscription(_ browserPanel: BrowserPanel) {
        let browserTabState = Publishers.CombineLatest4(
            browserPanel.$pageTitle.removeDuplicates(), browserPanel.$currentURL.removeDuplicates(),
            browserPanel.$isLoading.removeDuplicates(), browserPanel.$faviconPNGData.removeDuplicates(by: { $0 == $1 })
        )
        let subscription = browserTabState
        .combineLatest(browserPanel.$isMuted.removeDuplicates())
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak browserPanel] output in
            let ((_, _, isLoading, favicon), isMuted) = output
            guard let self = self,
                  let browserPanel = browserPanel,
                  let tabId = self.surfaceIdFromPanelId(browserPanel.id) else { return }
            self.publishBrowserOpenTabSuggestion(for: browserPanel)
            guard let existing = self.bonsplitController.tab(tabId) else { return }
            let nextTitle = browserPanel.displayTitle
            if self.panelTitles[browserPanel.id] != nextTitle {
                self.panelTitles[browserPanel.id] = nextTitle
            }
            let resolvedTitle = self.resolvedPanelTitle(panelId: browserPanel.id, fallback: nextTitle)
            SurfaceTabDisplayUpdatePlan(
                existing: existing,
                resolvedTitle: resolvedTitle,
                hasCustomTitle: self.panelCustomTitles[browserPanel.id] != nil,
                iconImageData: .some(favicon),
                isLoading: isLoading,
                isAudioMuted: isMuted
            ).apply(to: self.bonsplitController, tabId: tabId)
        }
        panelSubscriptions[browserPanel.id] = subscription
        publishBrowserOpenTabSuggestion(for: browserPanel)
        setPreferredBrowserProfileID(browserPanel.profileID)
    }

    private func syncBrowserAudioMuteStateForPanel(_ panelId: UUID, browserPanel: BrowserPanel? = nil) {
        guard let browserPanel = browserPanel ?? self.browserPanel(for: panelId),
              let tabId = surfaceIdFromPanelId(panelId),
              let tab = bonsplitController.tab(tabId),
              tab.isAudioMuted != browserPanel.isMuted else { return }
        bonsplitController.updateTab(tabId, isAudioMuted: browserPanel.isMuted)
    }

    func setPreferredBrowserProfileID(_ profileID: UUID?) {
        surfaceLifecycle.setPreferredBrowserProfileID(profileID)
    }

    private func resolvedNewBrowserProfileID(
        preferredProfileID: UUID? = nil,
        sourcePanelId: UUID? = nil
    ) -> UUID {
        surfaceLifecycle.resolvedNewBrowserProfileID(
            preferredProfileID: preferredProfileID,
            sourcePanelId: sourcePanelId
        ) ?? BrowserProfileStore.shared.effectiveLastUsedProfileID
    }

    private func installMarkdownPanelSubscription(_ markdownPanel: MarkdownPanel) {
        let subscription = Publishers.CombineLatest(
            markdownPanel.$displayTitle.removeDuplicates(),
            markdownPanel.$isDirty.removeDuplicates()
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak markdownPanel] newTitle, isDirty in
                guard let self,
                      let markdownPanel,
                      let tabId = self.surfaceIdFromPanelId(markdownPanel.id) else { return }
                guard let existing = self.bonsplitController.tab(tabId) else { return }

                if self.panelTitles[markdownPanel.id] != newTitle {
                    self.panelTitles[markdownPanel.id] = newTitle
                }
                let resolvedTitle = self.resolvedPanelTitle(panelId: markdownPanel.id, fallback: newTitle)
                SurfaceTabDisplayUpdatePlan(
                    existing: existing,
                    resolvedTitle: resolvedTitle,
                    hasCustomTitle: self.panelCustomTitles[markdownPanel.id] != nil,
                    isDirty: isDirty
                ).apply(to: self.bonsplitController, tabId: tabId)
            }
        panelSubscriptions[markdownPanel.id] = subscription
    }

    private func installFilePreviewPanelSubscription(_ filePreviewPanel: FilePreviewPanel) {
        let titleAndDirty = Publishers.CombineLatest(
            filePreviewPanel.$displayTitle.removeDuplicates(),
            filePreviewPanel.$isDirty.removeDuplicates()
        )
        let subscription = Publishers.CombineLatest(
            titleAndDirty,
            filePreviewPanel.$displayIcon.removeDuplicates()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak filePreviewPanel] titleAndDirty, displayIcon in
            guard let self,
                  let filePreviewPanel,
                  let tabId = self.surfaceIdFromPanelId(filePreviewPanel.id) else { return }
            let (newTitle, isDirty) = titleAndDirty
            guard let existing = self.bonsplitController.tab(tabId) else { return }

            if self.panelTitles[filePreviewPanel.id] != newTitle {
                self.panelTitles[filePreviewPanel.id] = newTitle
            }
            let resolvedTitle = self.resolvedPanelTitle(panelId: filePreviewPanel.id, fallback: newTitle)
            let resolvedIcon = RenderableSystemSymbol.resolvedSurfaceTabIcon(displayIcon)
            SurfaceTabDisplayUpdatePlan(
                existing: existing,
                resolvedTitle: resolvedTitle,
                hasCustomTitle: self.panelCustomTitles[filePreviewPanel.id] != nil,
                icon: .some(resolvedIcon),
                isDirty: isDirty
            ).apply(to: self.bonsplitController, tabId: tabId)
        }
        panelSubscriptions[filePreviewPanel.id] = subscription
    }

    private func installAgentSessionPanelSubscription(_ agentPanel: AgentSessionPanel) {
        agentPanel.onDisplayStateChanged = { [weak self, weak agentPanel] newTitle, isDirty in
            guard let self,
                  let agentPanel,
                  let tabId = self.surfaceIdFromPanelId(agentPanel.id) else { return }
            guard let existing = self.bonsplitController.tab(tabId) else { return }

            if self.panelTitles[agentPanel.id] != newTitle {
                self.panelTitles[agentPanel.id] = newTitle
            }
            let resolvedTitle = self.resolvedPanelTitle(panelId: agentPanel.id, fallback: newTitle)
            SurfaceTabDisplayUpdatePlan(
                existing: existing,
                resolvedTitle: resolvedTitle,
                hasCustomTitle: self.panelCustomTitles[agentPanel.id] != nil,
                isDirty: isDirty
            ).apply(to: self.bonsplitController, tabId: tabId)
        }
        agentSessionPanelCallbackIds.insert(agentPanel.id)
    }

    func discardAgentSessionPanelSubscription(panelId: UUID, panel: (any Panel)?) {
        if let agentPanel = panel as? AgentSessionPanel {
            agentPanel.onDisplayStateChanged = nil
        }
        agentSessionPanelCallbackIds.remove(panelId)
    }

    private func browserRemoteWorkspaceStatusSnapshot() -> BrowserRemoteWorkspaceStatus? {
        guard let target = remoteDisplayTarget else { return nil }
        return BrowserRemoteWorkspaceStatus(
            target: target,
            connectionState: remoteConnectionState,
            heartbeatCount: remoteHeartbeatCount,
            lastHeartbeatAt: remoteLastHeartbeatAt
        )
    }

    private func applyBrowserRemoteWorkspaceStatusToPanels() {
        let snapshot = browserRemoteWorkspaceStatusSnapshot()
        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            browserPanel.setRemoteWorkspaceStatus(snapshot)
        }
    }

    // MARK: - Panel Access

    func panel(for surfaceId: TabID) -> (any Panel)? {
        guard let panelId = panelIdFromSurfaceId(surfaceId) else { return nil }
        return panels[panelId]
    }

    func terminalPanel(for panelId: UUID) -> TerminalPanel? {
        panels[panelId] as? TerminalPanel
    }

    func browserPanel(for panelId: UUID) -> BrowserPanel? {
        panels[panelId] as? BrowserPanel
    }

    func markdownPanel(for panelId: UUID) -> MarkdownPanel? {
        panels[panelId] as? MarkdownPanel
    }

    func filePreviewPanel(for panelId: UUID) -> FilePreviewPanel? {
        panels[panelId] as? FilePreviewPanel
    }

    /// The working directory app-level actions (diff viewer, configured commands)
    /// should target for this workspace: the focused panel's tracked directory, then
    /// its terminal's requested directory, then the workspace's current directory.
    /// Returns `nil` when none is known so callers can apply their own fallback.
    ///
    /// This is the focused-panel case of ``configTrackingDirectory(for:)`` (the same
    /// three-tier order); the tiers are spelled out here so the public entry point is
    /// self-contained.
    func resolvedWorkingDirectory() -> String? {
        surfaceDirectoryMetadata.resolvedWorkingDirectory()
    }

    private func resolvedPanelTitle(panelId: UUID, fallback: String) -> String {
        surfaceRegistry.resolvedPanelTitle(panelId: panelId, fallback: fallback)
    }

    private func syncPinnedStateForTab(_ tabId: TabID, panelId: UUID) {
        surfaceRegistry.syncPinnedStateForTab(tabId, panelId: panelId)
    }

    private func hasVisibleNotificationIndicator(panelId: UUID) -> Bool {
        unreadModel.hasVisibleNotificationIndicator(panelId: panelId)
    }

    private func hasUnreadNotification(panelId: UUID) -> Bool {
        unreadModel.hasUnreadNotification(panelId: panelId)
    }

    private func attentionPersistentState() -> WorkspaceAttentionPersistentState {
        unreadModel.attentionPersistentState()
    }

    private func requestAttentionFlash(panelId: UUID, reason: WorkspaceAttentionFlashReason) {
        unreadModel.requestAttentionFlash(panelId: panelId, reason: reason)
    }

    private func syncUnreadBadgeStateForPanel(_ panelId: UUID) {
        unreadModel.syncUnreadBadgeStateForPanel(panelId)
    }

    private func syncUnreadBadgeStateForAllPanels() {
        unreadModel.syncUnreadBadgeStateForAllPanels()
    }

    func syncPanelDerivedWorkspaceUnread() {
        unreadModel.syncPanelDerivedWorkspaceUnread()
    }

    var hasWorkspaceContributingRestoredUnreadIndicator: Bool {
        unreadModel.hasWorkspaceContributingRestoredUnreadIndicator
    }

    private func normalizePinnedTabs(in paneId: PaneID) {
        surfaceRegistry.normalizePinnedTabs(in: paneId)
    }

    // Internal (not private) so `Workspace`'s `WorkspaceContextMenuHosting`
    // conformance can use it as the protocol witness for the create-to-right
    // index math the context-menu coordinator drives.
    func insertionIndexToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> Int {
        surfaceRegistry.insertionIndexToRight(of: anchorTabId, inPane: paneId)
    }

    /// Sets, replaces, or clears (empty/nil `title`) a panel custom title.
    ///
    /// `.auto` writes are rejected when a user-set title exists, and `.auto`
    /// never clears. Returns whether the write landed.
    @discardableResult
    func setPanelCustomTitle(panelId: UUID, title: String?, source: CustomTitleSource = .user) -> Bool {
        surfaceRegistry.setPanelCustomTitle(panelId: panelId, title: title, source: source)
    }

    func isPanelPinned(_ panelId: UUID) -> Bool {
        surfaceRegistry.isPanelPinned(panelId)
    }

    func panelKind(panelId: UUID) -> String? {
        surfaceRegistry.panelKind(panelId: panelId)
    }
    private var backgroundPrimeTerminalPanels: [TerminalPanel] {
        var seenPanelIds = Set<UUID>()
        return bonsplitController.allPaneIds.compactMap { paneId -> TerminalPanel? in
            guard let tabId = bonsplitController.selectedTab(inPane: paneId)?.id ?? bonsplitController.tabs(inPane: paneId).first?.id, let panelId = panelIdFromSurfaceId(tabId), seenPanelIds.insert(panelId).inserted else { return nil }
            return panels[panelId] as? TerminalPanel
        }
    }

    private func hasBackgroundSurfaceStartWork(for panel: TerminalPanel) -> Bool {
        panel.surface.hasDeferredStartupWorkForBackgroundStart() ||
            pendingTerminalInput.hasObservers(forPanelId: panel.id)
    }

    private var backgroundPrimeTerminalPanelsNeedingSurfaceStart: [TerminalPanel] {
        backgroundPrimeTerminalPanels.filter { panel in
            panel.surface.surface == nil && hasBackgroundSurfaceStartWork(for: panel)
        }
    }

    func hasBackgroundPrimeTerminalSurfaceStartWork() -> Bool {
        backgroundPrimeTerminalPanels.contains {
            hasBackgroundSurfaceStartWork(for: $0)
        }
    }

    func requestBackgroundPrimeTerminalSurfaceStartIfNeeded() {
        backgroundPrimeTerminalPanelsNeedingSurfaceStart.forEach {
            $0.surface.requestBackgroundSurfaceStartIfNeeded()
        }
    }

    func hasLoadedBackgroundPrimeTerminalSurface() -> Bool {
        backgroundPrimeTerminalPanels.allSatisfy { panel in
            panel.surface.surface != nil || !hasBackgroundSurfaceStartWork(for: panel)
        }
    }

    @discardableResult
    func preloadTerminalPanelForDebugStress(
        tabId: TabID,
        inPane paneId: PaneID
    ) -> TerminalPanel? {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let terminalPanel = panels[panelId] as? TerminalPanel else {
            return nil
        }

        debugStressPreloadSelectionDepth += 1
        defer { debugStressPreloadSelectionDepth -= 1 }
        let isVisibleSelection =
            bonsplitController.focusedPaneId == paneId &&
            bonsplitController.selectedTab(inPane: paneId)?.id == tabId &&
            terminalPanel.surface.isViewInWindow &&
            terminalPanel.hostedView.superview != nil

        if isVisibleSelection {
            terminalPanel.requestViewReattach()
            scheduleTerminalGeometryReconcile()
        }
        terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
        return terminalPanel
    }

    func scheduleDebugStressTerminalGeometryReconcile() {
        scheduleTerminalGeometryReconcile()
    }

    func hasLoadedTerminalSurface() -> Bool {
        let terminalPanels = panels.values.compactMap { $0 as? TerminalPanel }
        guard !terminalPanels.isEmpty else { return true }
        return terminalPanels.contains { $0.surface.surface != nil }
    }

    func panelTitle(panelId: UUID) -> String? {
        surfaceRegistry.panelTitle(panelId: panelId)
    }

    func setPanelPinned(panelId: UUID, pinned: Bool) {
        surfaceRegistry.setPanelPinned(panelId: panelId, pinned: pinned)
    }

    func markPanelUnread(_ panelId: UUID) {
        unreadModel.markPanelUnread(panelId)
    }

    func preferredUnreadPanelIdForJump() -> UUID? {
        unreadModel.preferredUnreadPanelIdForJump()
    }

    func markPanelRead(_ panelId: UUID) {
        unreadModel.markPanelRead(panelId)
    }

    func clearUnreadAfterJump(panelId: UUID?) {
        unreadModel.clearUnreadAfterJump(panelId: panelId)
    }

    func clearManualUnread(panelId: UUID) {
        unreadModel.clearManualUnread(panelId: panelId)
    }

    @discardableResult
    func clearAllPanelUnreadIndicatorsForWorkspaceRead() -> Bool {
        unreadModel.clearAllPanelUnreadIndicatorsForWorkspaceRead()
    }

    func restorePanelUnreadIndicator(
        _ panelId: UUID,
        contributesToWorkspaceUnread: Bool = true
    ) {
        unreadModel.restorePanelUnreadIndicator(
            panelId,
            contributesToWorkspaceUnread: contributesToWorkspaceUnread
        )
    }

    func clearRestoredUnreadIndicator(panelId: UUID) {
        unreadModel.clearRestoredUnreadIndicator(panelId: panelId)
    }

    func hasRestoredUnreadIndicator(panelId: UUID) -> Bool {
        unreadModel.hasRestoredUnreadIndicator(panelId: panelId)
    }

    func restoredUnreadIndicatorContributesToWorkspace(panelId: UUID) -> Bool? {
        unreadModel.restoredUnreadIndicatorContributesToWorkspace(panelId: panelId)
    }

    static func shouldShowUnreadIndicator(
        hasUnreadNotification: Bool,
        hasPanelUnreadIndicator: Bool,
        isWorkspaceManuallyUnread: Bool = false,
        isWorkspaceManualUnreadRepresentative: Bool = false
    ) -> Bool {
        WorkspaceUnreadModel.shouldShowUnreadIndicator(
            hasUnreadNotification: hasUnreadNotification,
            hasPanelUnreadIndicator: hasPanelUnreadIndicator,
            isWorkspaceManuallyUnread: isWorkspaceManuallyUnread,
            isWorkspaceManualUnreadRepresentative: isWorkspaceManualUnreadRepresentative
        )
    }

    // MARK: - SurfaceRegistryHosting (live seam for SurfaceRegistryModel)

    func surfaceRegistryPanelExists(_ panelId: UUID) -> Bool {
        panels[panelId] != nil
    }

    func surfaceRegistryPanelDisplayTitle(panelId: UUID) -> String? {
        panels[panelId]?.displayTitle
    }

    func surfaceRegistryPanelKind(panelId: UUID) -> String? {
        guard let panel = panels[panelId] else { return nil }
        return panel.panelType.surfaceKind.rawValue
    }

    func surfaceRegistrySurfaceId(forPanelId panelId: UUID) -> TabID? {
        surfaceIdFromPanelId(panelId)
    }

    func surfaceRegistryPanelId(forSurfaceId surfaceId: TabID) -> UUID? {
        panelIdFromSurfaceId(surfaceId)
    }

    func surfaceRegistryPaneId(forPanelId panelId: UUID) -> PaneID? {
        paneId(forPanelId: panelId)
    }

    func surfaceRegistryTab(_ tabId: TabID) -> Bonsplit.Tab? {
        bonsplitController.tab(tabId)
    }

    func surfaceRegistryTabs(inPane paneId: PaneID) -> [Bonsplit.Tab] {
        bonsplitController.tabs(inPane: paneId)
    }

    @discardableResult
    func surfaceRegistryReorderTab(_ tabId: TabID, toIndex index: Int) -> Bool {
        bonsplitController.reorderTab(tabId, toIndex: index)
    }

    func surfaceRegistryUpdateTab(_ tabId: TabID, title: String, hasCustomTitle: Bool) {
        bonsplitController.updateTab(tabId, title: title, hasCustomTitle: hasCustomTitle)
    }

    func surfaceRegistryUpdateTab(_ tabId: TabID, kind: String, isPinned: Bool) {
        bonsplitController.updateTab(tabId, kind: .some(kind), isPinned: isPinned)
    }

    func surfaceRegistryUpdateTab(_ tabId: TabID, isPinned: Bool) {
        bonsplitController.updateTab(tabId, isPinned: isPinned)
    }

    var surfaceRegistryPanelCount: Int {
        panels.count
    }

    var surfaceRegistryWorkspaceCustomTitle: String? {
        customTitle
    }

    var surfaceRegistryWorkspaceTitle: String {
        get { title }
        set { title = newValue }
    }

    var surfaceRegistryWorkspaceProcessTitle: String {
        get { processTitle }
        set { processTitle = newValue }
    }

    func surfaceRegistryLogUpdatePanelTitle(
        panelId: UUID,
        trimmedTitle: String,
        panelCount: Int,
        hasCustomTitle: Bool,
        didMutatePanelTitle: Bool,
        didMutateWorkspaceTitle: Bool
    ) {
#if DEBUG
        cmuxDebugLog(
            "workspace.title.updatePanel workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) panels=\(panelCount) custom=\(hasCustomTitle ? 1 : 0) " +
            "panelChanged=\(didMutatePanelTitle ? 1 : 0) workspaceChanged=\(didMutateWorkspaceTitle ? 1 : 0) " +
            "title=\"\(trimmedTitle.debugDescriptionPreview(limit: 80))\""
        )
#endif
    }

    var surfaceRegistryIsRemoteTmuxMirror: Bool {
        isRemoteTmuxMirror
    }

    func surfaceRegistryHandleMirrorWindowRenamed(panelId: UUID, title: String) {
        hostEnvironment?.remoteTmuxController.handleMirrorWindowRenamed(
            workspaceId: id, panelId: panelId, title: title
        )
    }

    // MARK: - WorkspaceUnreadHosting (live seam for WorkspaceUnreadModel)

    func workspaceUnreadPanelExists(_ panelId: UUID) -> Bool {
        panels[panelId] != nil
    }

    func workspaceUnreadPanelIds() -> Set<UUID> {
        Set(panels.keys)
    }

    func workspaceUnreadPanelHasTab(_ panelId: UUID) -> Bool {
        surfaceIdFromPanelId(panelId) != nil
    }

    func workspaceUnreadHasVisibleNotificationIndicator(panelId: UUID) -> Bool {
        hostEnvironment?.notificationStore?.hasVisibleNotificationIndicator(forTabId: id, surfaceId: panelId) ?? false
    }

    func workspaceUnreadHasUnreadNotification(panelId: UUID) -> Bool {
        hostEnvironment?.notificationStore?.hasUnreadNotification(forTabId: id, surfaceId: panelId) ?? false
    }

    func workspaceUnreadFocusedReadPanelId() -> UUID? {
        hostEnvironment?.notificationStore?.focusedReadIndicatorSurfaceId(forTabId: id)
    }

    func workspaceUnreadTriggerPanelFlash(panelId: UUID, reason: WorkspaceAttentionFlashReason) {
        panels[panelId]?.triggerFlash(reason: reason)
    }

    func workspaceUnreadNotificationHasManualUnread() -> Bool {
        hostEnvironment?.notificationStore?.hasManualUnread(forTabId: id) ?? false
    }

    func workspaceUnreadRepresentativePanelId() -> UUID? {
        representativePanelIdForWorkspaceManualUnread()
    }

    func workspaceUnreadApplyBadge(panelId: UUID, showsNotificationBadge: Bool) {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        if let existing = bonsplitController.tab(tabId), existing.showsNotificationBadge == showsNotificationBadge {
            return
        }
        bonsplitController.updateTab(tabId, showsNotificationBadge: showsNotificationBadge)
    }

    func workspaceUnreadSetPanelDerivedUnread(_ isUnread: Bool) {
        hostEnvironment?.notificationStore?.setPanelDerivedUnread(isUnread, forTabId: id)
    }

    func workspaceUnreadNotificationMarkRead(panelId: UUID) {
        hostEnvironment?.notificationStore?.markRead(forTabId: id, surfaceId: panelId)
    }

    func workspaceUnreadNotificationMarkReadWorkspace() {
        hostEnvironment?.notificationStore?.markRead(forTabId: id)
    }

    func workspaceUnreadNotificationClearRestoredUnreadIndicator() {
        _ = hostEnvironment?.notificationStore?.clearRestoredUnreadIndicator(forTabId: id)
    }

    // MARK: - SurfaceMetadataHosting (live seam for WorkspaceSurfaceMetadataModel)

    var surfaceMetadataFocusedPanelId: UUID? {
        focusedPanelId
    }

    func surfaceMetadataPanelExists(panelId: UUID) -> Bool {
        panels[panelId] != nil
    }

    var surfaceMetadataCurrentDirectory: String {
        get { currentDirectory }
        set { currentDirectory = newValue }
    }

    var surfaceMetadataSurfaceTabBarDirectory: String? {
        get { surfaceTabBarDirectory }
        set { surfaceTabBarDirectory = newValue }
    }

    var surfaceMetadataIsRemoteTmuxMirror: Bool {
        isRemoteTmuxMirror
    }

    func surfaceMetadataRequestedWorkingDirectory(panelId: UUID) -> String? {
        terminalPanel(for: panelId)?.requestedWorkingDirectory
    }

    func surfaceMetadataRestoredGuardedWorkingDirectory(panelId: UUID) -> String? {
        restoredGuardedWorkingDirectoriesByPanelId[panelId]
    }

    func surfaceMetadataClearRestoredGuardedWorkingDirectory(panelId: UUID) {
        restoredGuardedWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
    }

    var surfaceMetadataAgentListeningPorts: [Int] {
        agentListeningPorts
    }

    var surfaceMetadataRemoteDetectedPorts: [Int] {
        remoteDetectedPorts
    }

    var surfaceMetadataRemoteForwardedPorts: [Int] {
        remoteForwardedPorts
    }

    func surfaceMetadataLogIgnoredRestoredCwdReport(
        panelId: UUID,
        missingVolumeRoot: String,
        savedDirectory: String,
        reportedDirectory: String
    ) {
#if DEBUG
        cmuxDebugLog(
            "session.restore.cwdReport.ignored panel=\(panelId.uuidString.prefix(5)) " +
            "missingVolume=\(missingVolumeRoot) saved=\(savedDirectory) reported=\(reportedDirectory)"
        )
#endif
    }

    // MARK: - WorkspaceTitleHosting (live seam for WorkspaceTitleModel)

    var workspaceTitleText: String {
        get { title }
        set { title = newValue }
    }

    var workspaceTitleCustomTitle: String? {
        get { customTitle }
        set { customTitle = newValue }
    }

    var workspaceTitleCustomTitleSource: CustomTitleSource? {
        get { customTitleSource }
        set { customTitleSource = newValue }
    }

    var workspaceTitleCustomDescription: String? {
        get { customDescription }
        set { customDescription = newValue }
    }

    var workspaceTitleProcessTitle: String {
        get { processTitle }
        set { processTitle = newValue }
    }

    func workspaceTitleLogApplyProcess(from previousTitle: String, to title: String) {
#if DEBUG
        cmuxDebugLog(
            "workspace.title.applyProcess workspace=\(id.uuidString.prefix(5)) " +
            "from=\"\(previousTitle.debugDescriptionPreview(limit: 80))\" " +
            "to=\"\(title.debugDescriptionPreview(limit: 80))\""
        )
#endif
    }

    func workspaceTitleLogCustomDescriptionUpdate(input description: String?, normalized normalizedDescription: String?) {
#if DEBUG
        let inputNewlines = description?.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        } ?? 0
        let normalizedNewlines = normalizedDescription?.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        } ?? 0
        cmuxDebugLog(
            "workspace.customDescription.update workspace=\(id.uuidString.prefix(8)) " +
            "inputLen=\((description as NSString?)?.length ?? 0) " +
            "inputNewlines=\(inputNewlines) " +
            "normalizedLen=\((normalizedDescription as NSString?)?.length ?? 0) " +
            "normalizedNewlines=\(normalizedNewlines) " +
            "input=\"\(description?.debugDescriptionPreview() ?? "nil")\" " +
            "normalized=\"\(normalizedDescription?.debugDescriptionPreview() ?? "nil")\""
        )
#endif
    }

    // MARK: - WorkspaceAppearanceHosting (live seam for WorkspaceAppearanceModel)

    var workspaceAppearanceCustomColor: String? {
        get { customColor }
        set { customColor = newValue }
    }

    var workspaceAppearanceTerminalScrollBarHidden: Bool {
        get { terminalScrollBarHidden }
        set { terminalScrollBarHidden = newValue }
    }

    func workspaceAppearanceNormalizedColorHex(_ hex: String) -> String? {
        WorkspaceTabColorSettings.normalizedHex(hex)
    }

    func workspaceAppearancePostTerminalScrollBarHiddenDidChange() {
        NotificationCenter.default.post(
            name: Self.terminalScrollBarHiddenDidChangeNotification,
            object: self
        )
    }

    // MARK: - Title Management

    /// `Workspace.CustomTitleSource`, lifted to ``CmuxWorkspaces/CustomTitleSource``
    /// and kept reachable at the nested spelling so every call site and `Codable`
    /// snapshot field stays byte-identical.
    typealias CustomTitleSource = CmuxWorkspaces.CustomTitleSource

    var hasCustomTitle: Bool {
        titleModel.hasCustomTitle
    }

    var effectiveCustomTitleSource: CustomTitleSource? {
        titleModel.effectiveCustomTitleSource
    }

    var hasCustomDescription: Bool {
        titleModel.hasCustomDescription
    }

    func applyProcessTitle(_ title: String) {
        titleModel.applyProcessTitle(title)
    }

    func setCustomColor(_ hex: String?) {
        appearanceModel.setCustomColor(hex)
    }

    func setTerminalScrollBarHidden(_ hidden: Bool) {
        appearanceModel.setTerminalScrollBarHidden(hidden)
    }

    @discardableResult
    func setCustomTitle(_ title: String?, source: CustomTitleSource = .user) -> Bool {
        titleModel.setCustomTitle(title, source: source)
    }

    func setCustomDescription(_ description: String?) {
        titleModel.setCustomDescription(description)
    }

    // MARK: - Directory Updates

    private func configTrackingDirectory(for panelId: UUID?) -> String? {
        surfaceDirectoryMetadata.configTrackingDirectory(for: panelId)
    }

    @discardableResult
    func updatePanelDirectory(panelId: UUID, directory: String) -> Bool {
        surfaceDirectoryMetadata.updatePanelDirectory(panelId: panelId, directory: directory)
    }

    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {
        guard let previousState = surfaceDirectoryMetadata.applyPanelShellActivityState(
            panelId: panelId,
            state: state
        ) else { return }
        if let restoredAgent = restoredAgentSnapshotsByPanelId[panelId] {
            updateRestoredAgentResumeState(
                panelId: panelId,
                restoredAgent: restoredAgent,
                shellState: state
            )
        }
#if DEBUG
        cmuxDebugLog(
            "surface.shellState workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) from=\(previousState.rawValue) to=\(state.rawValue)"
        )
#endif
    }

    /// Forwards to ``AgentHibernationCoordinator/setAgentLifecycle(key:panelId:lifecycle:)``.
    func setAgentLifecycle(
        key: String,
        panelId: UUID?,
        lifecycle: AgentHibernationLifecycleState
    ) {
        agentHibernationCoordinator.setAgentLifecycle(key: key, panelId: panelId, lifecycle: lifecycle)
    }

    /// Forwards to ``AgentHibernationCoordinator/clearAgentLifecycle(key:panelId:)``.
    @discardableResult
    func clearAgentLifecycle(key: String, panelId: UUID? = nil) -> Bool {
        agentHibernationCoordinator.clearAgentLifecycle(key: key, panelId: panelId)
    }

    /// Forwards to ``AgentHibernationCoordinator/clearAgentLifecycleStates(panelId:)``.
    func clearAgentLifecycleStates(panelId: UUID) {
        agentHibernationCoordinator.clearAgentLifecycleStates(panelId: panelId)
    }

    /// Forwards to ``AgentHibernationCoordinator/clearAllAgentLifecycleStates()``.
    func clearAllAgentLifecycleStates() {
        agentHibernationCoordinator.clearAllAgentLifecycleStates()
    }

    /// Forwards to ``AgentHibernationCoordinator/agentHibernationLifecycleState(panelId:fallback:priority:unknown:)``,
    /// passing the workspace's lifecycle precedence order (running > needsInput > unknown > idle).
    func agentHibernationLifecycleState(
        panelId: UUID,
        fallback: AgentHibernationLifecycleState?
    ) -> AgentHibernationLifecycleState {
        agentHibernationCoordinator.agentHibernationLifecycleState(
            panelId: panelId,
            fallback: fallback,
            priority: [.running, .needsInput, .unknown, .idle],
            unknown: .unknown
        )
    }

    /// Forwards to ``AgentHibernationCoordinator/restorableAgentForHibernation(panelId:indexSnapshot:snapshotHasResumeCommand:)``,
    /// resolving the session-index snapshot app-side so `RestorableAgentSessionIndex` stays out of
    /// the package.
    func restorableAgentForHibernation(
        panelId: UUID,
        index: RestorableAgentSessionIndex
    ) -> SessionRestorableAgentSnapshot? {
        agentHibernationCoordinator.restorableAgentForHibernation(
            panelId: panelId,
            indexSnapshot: index.snapshot(workspaceId: id, panelId: panelId),
            snapshotHasResumeCommand: { $0.resumeCommand != nil }
        )
    }

    /// Forwards to ``AgentHibernationCoordinator/enterAgentHibernation(panelId:agent:lastActivityAt:agentHasResumeCommand:)``.
    func enterAgentHibernation(
        panelId: UUID,
        agent: SessionRestorableAgentSnapshot,
        lastActivityAt: Date
    ) {
        agentHibernationCoordinator.enterAgentHibernation(
            panelId: panelId,
            agent: agent,
            lastActivityAt: lastActivityAt,
            agentHasResumeCommand: { $0.resumeCommand != nil }
        )
    }

    /// Forwards to ``AgentHibernationCoordinator/resumeAgentHibernation(panelId:focus:)``.
    @discardableResult
    func resumeAgentHibernation(panelId: UUID, focus: Bool) -> Bool {
        agentHibernationCoordinator.resumeAgentHibernation(panelId: panelId, focus: focus)
    }

    /// Forwards to ``AgentHibernationCoordinator/resumeVisibleAgentHibernationPanels(panelIds:)``.
    @discardableResult
    func resumeVisibleAgentHibernationPanels(panelIds: Set<UUID>) -> Bool {
        agentHibernationCoordinator.resumeVisibleAgentHibernationPanels(panelIds: panelIds)
    }

    /// Forwards to ``AgentHibernationCoordinator/restoredAgentResumeStateForAcceptedSnapshot(panelId:)``.
    private func restoredAgentResumeStateForAcceptedSnapshot(panelId: UUID) -> RestoredAgentResumeState {
        agentHibernationCoordinator.restoredAgentResumeStateForAcceptedSnapshot(panelId: panelId)
    }

    /// Forwards to ``AgentHibernationCoordinator/updateRestoredAgentResumeState(panelId:restoredAgent:isCommandRunning:isPromptIdle:)``,
    /// mapping the panel's `PanelShellActivityState` to the two observed-transition flags app-side.
    private func updateRestoredAgentResumeState(
        panelId: UUID,
        restoredAgent: SessionRestorableAgentSnapshot,
        shellState: PanelShellActivityState
    ) {
        agentHibernationCoordinator.updateRestoredAgentResumeState(
            panelId: panelId,
            restoredAgent: restoredAgent,
            isCommandRunning: shellState == .commandRunning,
            isPromptIdle: shellState == .promptIdle
        )
    }

    /// Forwards to ``AgentHibernationCoordinator/invalidateRestoredAgentSnapshot(panelId:restoredAgent:)``.
    private func invalidateRestoredAgentSnapshot(
        panelId: UUID,
        restoredAgent: SessionRestorableAgentSnapshot
    ) {
        agentHibernationCoordinator.invalidateRestoredAgentSnapshot(
            panelId: panelId,
            restoredAgent: restoredAgent
        )
    }

    /// Forwards to ``AgentHibernationCoordinator/clearRestoredAgentSnapshot(panelId:)``.
    private func clearRestoredAgentSnapshot(panelId: UUID) {
        agentHibernationCoordinator.clearRestoredAgentSnapshot(panelId: panelId)
    }

    /// Forwards to ``AgentHibernationCoordinator/clearRestoredAgentResumeBinding(panelId:restoredAgent:)``.
    private func clearRestoredAgentResumeBinding(
        panelId: UUID,
        restoredAgent: SessionRestorableAgentSnapshot
    ) {
        agentHibernationCoordinator.clearRestoredAgentResumeBinding(
            panelId: panelId,
            restoredAgent: restoredAgent
        )
    }

    /// Forwards to ``AgentHibernationCoordinator/setSurfaceResumeBinding(_:panelId:)``.
    @discardableResult
    func setSurfaceResumeBinding(_ binding: SurfaceResumeBindingSnapshot, panelId: UUID) -> Bool {
        agentHibernationCoordinator.setSurfaceResumeBinding(binding, panelId: panelId)
    }

    /// Forwards to ``AgentHibernationCoordinator/clearSurfaceResumeBinding(panelId:)``.
    @discardableResult
    func clearSurfaceResumeBinding(panelId: UUID) -> Bool {
        agentHibernationCoordinator.clearSurfaceResumeBinding(panelId: panelId)
    }

    /// Forwards to ``AgentHibernationCoordinator/surfaceResumeBinding(panelId:)``.
    func surfaceResumeBinding(panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        agentHibernationCoordinator.surfaceResumeBinding(panelId: panelId)
    }

    func panelNeedsConfirmClose(panelId: UUID, fallbackNeedsConfirmClose: Bool) -> Bool {
        Self.resolveCloseConfirmation(
            shellActivityState: panelShellActivityStates[panelId],
            fallbackNeedsConfirmClose: fallbackNeedsConfirmClose
        )
    }

    func panelNeedsConfirmClose(panelId: UUID) -> Bool {
        guard let panel = panels[panelId] else { return false }
        // Mirrored remote tmux window-tab: closing it kills the remote window,
        // and its manual-I/O surface has no local child process for the ghostty
        // fallback (which reports "needs confirm" whenever the cursor isn't at a
        // marked prompt — i.e. always, for a mirror). Ask the control connection
        // whether any of the window's panes is running an active command instead.
        if isRemoteTmuxMirror,
           let activity = hostEnvironment?.remoteTmuxController
               .cachedMirrorTabActivity(workspaceId: id, panelId: panelId) {
            return activity.hasActiveCommand
        }
        if let terminalPanel = panel as? TerminalPanel {
            return panelNeedsConfirmClose(
                panelId: panelId,
                fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose()
            )
        }
        return panel.isDirty
    }

    /// Forwards to ``WorkspaceSidebarMetadataModel/updatePanelGitBranch(panelId:branch:isDirty:focusedPanelId:)``.
    func updatePanelGitBranch(panelId: UUID, branch: String, isDirty: Bool) {
        sidebarMetadata.updatePanelGitBranch(
            panelId: panelId,
            branch: branch,
            isDirty: isDirty,
            focusedPanelId: focusedPanelId
        )
    }

    /// Forwards to ``WorkspaceSidebarMetadataModel/clearPanelGitBranch(panelId:focusedPanelId:)``.
    func clearPanelGitBranch(panelId: UUID) {
        sidebarMetadata.clearPanelGitBranch(panelId: panelId, focusedPanelId: focusedPanelId)
    }

    /// Forwards to ``WorkspaceSidebarMetadataModel/updatePanelPullRequest(panelId:number:label:url:status:branch:isStale:focusedPanelId:)``.
    func updatePanelPullRequest(
        panelId: UUID,
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String? = nil,
        isStale: Bool = false
    ) {
        sidebarMetadata.updatePanelPullRequest(
            panelId: panelId,
            number: number,
            label: label,
            url: url,
            status: status,
            branch: branch,
            isStale: isStale,
            focusedPanelId: focusedPanelId
        )
    }

    /// Forwards to ``WorkspaceSidebarMetadataModel/clearPanelPullRequest(panelId:focusedPanelId:)``.
    func clearPanelPullRequest(panelId: UUID) {
        sidebarMetadata.clearPanelPullRequest(panelId: panelId, focusedPanelId: focusedPanelId)
    }

    /// Forwards to ``WorkspaceSidebarMetadataModel/clearPullRequestMetadata()``.
    func clearSidebarPullRequestMetadata() {
        sidebarMetadata.clearPullRequestMetadata()
    }

    /// Forwards to ``WorkspaceSidebarMetadataModel/clearGitMetadata()``.
    func clearSidebarGitMetadata() {
        sidebarMetadata.clearGitMetadata()
    }

    func resetSidebarContext(reason: String = "unspecified") {
        agentPIDs.removeAll()
        agentPIDPanelIdsByKey.removeAll()
        agentPIDKeysByPanelId.removeAll()
        clearAllAgentLifecycleStates()
        agentListeningPorts.removeAll()
        latestConversationMessage = nil
        latestSubmittedMessage = nil
        latestSubmittedAt = nil
        surfaceListeningPorts.removeAll()
        listeningPorts.removeAll()
        // Clears statusEntries, logEntries, progress, gitBranch,
        // panelGitBranches, pullRequest, panelPullRequests, and metadataBlocks
        // (the sidebar-metadata fields owned by `sidebarMetadata`), in the same
        // relative order and with the same unconditional assignments the legacy
        // inline body used.
        sidebarMetadata.reset()
        resetBrowserPanelsForContextChange(reason: reason)
    }

    func resetBrowserPanelsForContextChange(reason: String) {
        let browserPanels = panels.values.compactMap { $0 as? BrowserPanel }
        guard !browserPanels.isEmpty else { return }

#if DEBUG
        cmuxDebugLog(
            "workspace.contextReset.browserPanels workspace=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) count=\(browserPanels.count)"
        )
#endif

        for browserPanel in browserPanels {
            browserPanel.resetForWorkspaceContextChange(reason: reason)
            let nextTitle = browserPanel.displayTitle
            _ = updatePanelTitle(panelId: browserPanel.id, title: nextTitle)

            guard let tabId = surfaceIdFromPanelId(browserPanel.id),
                  let existing = bonsplitController.tab(tabId) else {
                continue
            }

            let faviconUpdate: Data?? = existing.iconImageData == nil ? nil : .some(nil)
            let loadingUpdate: Bool? = existing.isLoading ? false : nil

            guard faviconUpdate != nil || loadingUpdate != nil else {
                continue
            }

            bonsplitController.updateTab(
                tabId,
                iconImageData: faviconUpdate,
                hasCustomTitle: panelCustomTitles[browserPanel.id] != nil,
                isLoading: loadingUpdate
            )
        }
    }

    @discardableResult
    func updatePanelTitle(panelId: UUID, title: String) -> Bool {
        surfaceRegistry.updatePanelTitle(panelId: panelId, title: title)
    }

    func pruneSurfaceMetadata(validSurfaceIds: Set<UUID>) {
        pendingTerminalInput.removeObservers(forPanelIdsNotIn: validSurfaceIds)
        panelDirectories = panelDirectories.filter { validSurfaceIds.contains($0.key) }
        panelTitles = panelTitles.filter { validSurfaceIds.contains($0.key) }
        panelCustomTitles = panelCustomTitles.filter { validSurfaceIds.contains($0.key) }
        panelCustomTitleSources = panelCustomTitleSources.filter { validSurfaceIds.contains($0.key) }
        pinnedPanelIds = pinnedPanelIds.filter { validSurfaceIds.contains($0) }
        manualUnreadPanelIds = manualUnreadPanelIds.filter { validSurfaceIds.contains($0) }
        restoredUnreadPanelIndicators = restoredUnreadPanelIndicators.filter { validSurfaceIds.contains($0.key) }
        panelGitBranches = panelGitBranches.filter { validSurfaceIds.contains($0.key) }
        manualUnreadMarkedAt = manualUnreadMarkedAt.filter { validSurfaceIds.contains($0.key) }
        surfaceListeningPorts = surfaceListeningPorts.filter { validSurfaceIds.contains($0.key) }
        surfaceTTYNames = surfaceTTYNames.filter { validSurfaceIds.contains($0.key) }
        restoredGuardedWorkingDirectoriesByPanelId = restoredGuardedWorkingDirectoriesByPanelId.filter {
            validSurfaceIds.contains($0.key)
        }
        remoteRelaySession.retainRemotePTYSessionIDs(validSurfaceIds: validSurfaceIds)
        endedPersistentRemotePTYAttachSurfaceIds = endedPersistentRemotePTYAttachSurfaceIds.filter { validSurfaceIds.contains($0) }
        pruneRemoteRelaySurfaceAliases(validSurfaceIds: validSurfaceIds)
        remoteDetectedSurfaceIds = remoteDetectedSurfaceIds.filter { validSurfaceIds.contains($0) }
        panelShellActivityStates = panelShellActivityStates.filter { validSurfaceIds.contains($0.key) }
        panelPullRequests = panelPullRequests.filter { validSurfaceIds.contains($0.key) }
        let staleAgentPIDPanelIds = agentPIDKeysByPanelId.keys.filter { !validSurfaceIds.contains($0) }
        var didClearStaleAgentRuntime = false
        for panelId in staleAgentPIDPanelIds {
            let keys = agentPIDKeysByPanelId[panelId] ?? []
            for key in keys {
                if clearAgentPID(key: key, panelId: panelId, clearStatus: true, refreshPorts: false) {
                    didClearStaleAgentRuntime = true
                }
            }
        }
        if didClearStaleAgentRuntime {
            refreshTrackedAgentPorts()
        }
        restoredAgentSnapshotsByPanelId = restoredAgentSnapshotsByPanelId.filter {
            validSurfaceIds.contains($0.key)
        }
        surfaceResumeBindingsByPanelId = surfaceResumeBindingsByPanelId.filter {
            validSurfaceIds.contains($0.key)
        }
        restoredAgentResumeStatesByPanelId = restoredAgentResumeStatesByPanelId.filter {
            validSurfaceIds.contains($0.key)
        }
        invalidatedRestoredAgentFingerprintsByPanelId = invalidatedRestoredAgentFingerprintsByPanelId.filter {
            validSurfaceIds.contains($0.key)
        }
        syncRemotePortScanTTYs()
        recomputeListeningPorts()
    }

    func recomputeListeningPorts() {
        surfaceDirectoryMetadata.recomputeListeningPorts()
    }

    func sidebarOrderedPanelIds() -> [UUID] {
        let paneTabs: [String: [UUID]] = Dictionary(
            uniqueKeysWithValues: bonsplitController.allPaneIds.map { paneId in
                let panelIds = bonsplitController
                    .tabs(inPane: paneId)
                    .compactMap { panelIdFromSurfaceId($0.id) }
                return (paneId.id.uuidString, panelIds)
            }
        )

        let fallbackPanelIds = panels.keys.sorted { $0.uuidString < $1.uuidString }
        let tree = bonsplitController.treeSnapshot()
        return tree.orderedPanelIds(
            paneTabs: paneTabs,
            fallbackPanelIds: fallbackPanelIds
        )
    }

    /// The sidebar display-order projection, combining this workspace's live
    /// panel directories and per-panel metadata into the ordered sidebar rows
    /// through the ``SidebarMetadataHosting`` seam. Constructed per use; the
    /// projection is a stateless throwaway value holding only the host and
    /// metadata-model references.
    private var sidebarDisplayOrderProjection: SidebarDisplayOrderProjection {
        SidebarDisplayOrderProjection(host: self, metadata: sidebarMetadata)
    }

    // MARK: - SidebarMetadataHosting

    /// The currently focused panel id, exposed to ``SidebarDirectoryResolver``.
    var sidebarFocusedPanelId: UUID? { focusedPanelId }

    /// The workspace's current directory, exposed to ``SidebarDirectoryResolver``.
    var sidebarCurrentDirectory: String { currentDirectory }

    /// Whether this is a remote workspace, exposed to ``SidebarDirectoryResolver``.
    var sidebarIsRemoteWorkspace: Bool { isRemoteWorkspace }

    /// The panel's last-reported working directory, exposed to
    /// ``SidebarDirectoryResolver``.
    func sidebarPanelDirectory(for panelId: UUID) -> String? {
        panelDirectories[panelId]
    }

    /// The panel's terminal-requested working directory, exposed to
    /// ``SidebarDirectoryResolver``.
    func sidebarPanelRequestedWorkingDirectory(for panelId: UUID) -> String? {
        terminalPanel(for: panelId)?.requestedWorkingDirectory
    }

    /// The bonsplit spatial panel order, exposed to
    /// ``SidebarDisplayOrderProjection`` (the irreducible live-state read that
    /// stays in the `Workspace` shim).
    var sidebarSpatialPanelOrder: [UUID] { sidebarOrderedPanelIds() }

    /// Whether a panel is a remote-display surface, exposed to
    /// ``SidebarDisplayOrderProjection`` for the Finder-directory local-panel
    /// filter.
    func sidebarIsRemoteDisplaySurface(_ panelId: UUID) -> Bool {
        remoteDetectedSurfaceIds.contains(panelId)
            || isRemoteTerminalSurface(panelId)
            || pendingRemoteTerminalChildExitSurfaceIds.contains(panelId)
    }

    /// The structured-hook status entries currently visible for display,
    /// exposed to ``SidebarDisplayOrderProjection`` (the agent-visibility
    /// filtering reads live `Workspace` agent state and stays in the shim).
    var sidebarVisibleStatusEntriesForDisplay: [SidebarStatusEntry] {
        sidebarStatusEntriesVisibleForDisplay()
    }

    /// Forwards to ``SidebarDisplayOrderProjection/directoriesInDisplayOrder(orderedPanelIds:includeFallback:)``.
    func sidebarDirectoriesInDisplayOrder(orderedPanelIds: [UUID], includeFallback: Bool = true) -> [String] {
        sidebarDisplayOrderProjection.directoriesInDisplayOrder(
            orderedPanelIds: orderedPanelIds,
            includeFallback: includeFallback
        )
    }

    func sidebarDirectoriesInDisplayOrder() -> [String] {
        sidebarDisplayOrderProjection.directoriesInDisplayOrder()
    }

    func sidebarFinderDirectory() -> String? {
        sidebarDisplayOrderProjection.finderDirectory()
    }

    /// Forwards to ``SidebarDisplayOrderProjection/gitBranchesInDisplayOrder(orderedPanelIds:)``.
    func sidebarGitBranchesInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarGitBranchState] {
        sidebarDisplayOrderProjection.gitBranchesInDisplayOrder(orderedPanelIds: orderedPanelIds)
    }

    func sidebarGitBranchesInDisplayOrder() -> [SidebarGitBranchState] {
        sidebarDisplayOrderProjection.gitBranchesInDisplayOrder()
    }

    /// Forwards to ``SidebarDisplayOrderProjection/branchDirectoryEntriesInDisplayOrder(orderedPanelIds:)``.
    func sidebarBranchDirectoryEntriesInDisplayOrder(
        orderedPanelIds: [UUID]
    ) -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        sidebarDisplayOrderProjection.branchDirectoryEntriesInDisplayOrder(orderedPanelIds: orderedPanelIds)
    }

    func sidebarBranchDirectoryEntriesInDisplayOrder() -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        sidebarDisplayOrderProjection.branchDirectoryEntriesInDisplayOrder()
    }

    /// Forwards to ``SidebarDisplayOrderProjection/pullRequestsInDisplayOrder(orderedPanelIds:)``.
    func sidebarPullRequestsInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarPullRequestState] {
        sidebarDisplayOrderProjection.pullRequestsInDisplayOrder(orderedPanelIds: orderedPanelIds)
    }

    func sidebarPullRequestsInDisplayOrder() -> [SidebarPullRequestState] {
        sidebarDisplayOrderProjection.pullRequestsInDisplayOrder()
    }

    /// Forwards to ``SidebarDisplayOrderProjection/statusEntriesInDisplayOrder()``.
    func sidebarStatusEntriesInDisplayOrder() -> [SidebarStatusEntry] {
        sidebarDisplayOrderProjection.statusEntriesInDisplayOrder()
    }

    func sidebarMetadataBlocksInDisplayOrder() -> [SidebarMetadataBlock] {
        sidebarDisplayOrderProjection.metadataBlocksInDisplayOrder()
    }

    /// Forwards to
    /// ``WorkspaceSurfaceMetadataModel/conversationMessagePreview(from:maxLength:)``.
    static func conversationMessagePreview(from message: String?, maxLength: Int = 240) -> String? {
        WorkspaceSurfaceMetadataModel<PendingTabSelectionRequest>
            .conversationMessagePreview(from: message, maxLength: maxLength)
    }

    /// Forwards to ``WorkspaceSurfaceMetadataModel/recordConversationMessage(_:)``.
    @discardableResult
    func recordConversationMessage(_ message: String?) -> Bool {
        surfaceDirectoryMetadata.recordConversationMessage(message)
    }

    /// Forwards to ``WorkspaceSurfaceMetadataModel/recordSubmittedMessage(_:)``.
    @discardableResult
    func recordSubmittedMessage(_ message: String?) -> Bool {
        surfaceDirectoryMetadata.recordSubmittedMessage(message)
    }

    var isRemoteWorkspace: Bool {
        remoteConfiguration != nil
    }

    /// True when this workspace is an ephemeral mirror of a remote tmux session
    /// (created by ``RemoteTmuxController``). Such workspaces are rebuilt from
    /// the remote on each launch, so they are excluded from cmux's own session
    /// snapshot/restore to avoid resurrecting stale, disconnected copies.
    var isRemoteTmuxMirror: Bool = false

    /// Per-window multi-pane renderers, keyed by the window-tab's panel id. When
    /// a mirrored tmux window has more than one pane, its tab renders this
    /// in-tab split container (``RemoteTmuxWindowMirrorView``) instead of the
    /// single-surface ``PanelContentView``. Owned by ``RemoteTmuxSessionMirror``;
    /// the view layer only reads it.
    private(set) var remoteTmuxWindowMirrors: [UUID: RemoteTmuxWindowMirror] = [:]

    /// The multi-pane renderer for a window-tab's panel, if that window is
    /// currently multi-pane.
    func remoteTmuxWindowMirror(forPanelId panelId: UUID) -> RemoteTmuxWindowMirror? {
        remoteTmuxWindowMirrors[panelId]
    }

    /// Registers (or replaces) a window's multi-pane renderer.
    func setRemoteTmuxWindowMirror(_ mirror: RemoteTmuxWindowMirror?, forPanelId panelId: UUID) {
        // `remoteTmuxWindowMirrors` is an `@Observable` stored property; mutating
        // it invalidates the views that read it (`WorkspaceContentView` calls
        // `remoteTmuxWindowMirror(forPanelId:)`), so the former manual
        // `objectWillChange.send()` is no longer needed.
        if let mirror {
            remoteTmuxWindowMirrors[panelId] = mirror
        } else {
            remoteTmuxWindowMirrors.removeValue(forKey: panelId)
        }
    }

    var isRestorableInSessionSnapshot: Bool {
        if isRemoteTmuxMirror { return false }
        guard let remoteConfiguration else { return true }
        return remoteConfiguration.sessionSnapshot() != nil
    }

    @MainActor
    func isRemoteTerminalSurface(_ panelId: UUID) -> Bool {
        remoteSurfaceCoordinator.isRemoteTerminalSurface(panelId)
    }

    @MainActor
    func markRemoteTerminalSessionClosingIfLast(surfaceId: UUID) {
        remoteSurfaceCoordinator.markRemoteTerminalSessionClosingIfLast(surfaceId: surfaceId)
    }

    @MainActor
    func shouldKeepPersistentRemoteSurfaceOpenAfterChildExit(_ panelId: UUID) -> Bool {
        remoteSurfaceCoordinator.shouldKeepPersistentRemoteSurfaceOpenAfterChildExit(panelId)
    }

    @MainActor
    func shouldDemoteWorkspaceAfterChildExit(surfaceId: UUID) -> Bool {
        remoteSurfaceCoordinator.shouldDemoteWorkspaceAfterChildExit(surfaceId: surfaceId)
    }

    var remoteDisplayTarget: String? {
        remoteConfiguration?.displayTarget
    }

    var hasActiveRemoteTerminalSessions: Bool {
        activeRemoteTerminalSessionCount > 0
    }

    @MainActor
    func uploadDroppedFilesForRemoteTerminal(
        _ fileURLs: [URL],
        operation: TerminalImageTransferOperation,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        remoteSurfaceCoordinator.uploadDroppedFiles(fileURLs, operation: operation, completion: completion)
    }

    func syncRemotePortScanTTYs() {
        remoteSurfaceCoordinator.syncRemotePortScanTTYs()
    }

    func remotePTYSessionControllerForSocketCommand() -> RemoteSessionCoordinator? {
        remoteSurfaceCoordinator.remotePTYSessionControllerForSocketCommand()
    }

    func kickRemotePortScan(panelId: UUID, reason: PortScanKickReason = .command) {
        remoteSurfaceCoordinator.kickRemotePortScan(panelId: panelId, reason: reason)
    }

    /// Whether remote listening-port discovery may run, derived from the global
    /// sidebar ports-visibility settings. Mirrors the sidebar's own precedence
    /// (`sidebar.hideAllDetails` wins over `sidebar.showPorts`, see
    /// `SidebarWorkspaceAuxiliaryDetailVisibility.resolved`): when the ports
    /// detail is not displayed there is nothing for the remote scans to
    /// populate, so the backend ssh port-scan loop is suspended (issue #6123).
    static func remotePortScanningEnabledFromSettings(defaults: UserDefaults = .standard) -> Bool {
        RemotePortScanningPolicy().isEnabled(defaults: defaults)
    }

    /// Pushes the current remote port-scanning enablement to this workspace's
    /// active remote session, if any. No-op for non-remote workspaces.
    func applyRemotePortScanningEnabled(_ enabled: Bool) {
        remoteSurfaceCoordinator.applyRemotePortScanningEnabled(enabled)
    }

    func listRemotePTYSessions() throws -> [[String: Any]] {
        try remoteSurfaceCoordinator.listRemotePTYSessions()
    }

    func closeRemotePTYSession(sessionID: String) throws {
        try remoteSurfaceCoordinator.closeRemotePTYSession(sessionID: sessionID)
    }

    func startRemotePTYBridge(
        sessionID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool
    ) throws -> RemotePTYBridgeServer.Endpoint {
        try remoteSurfaceCoordinator.startRemotePTYBridge(
            sessionID: sessionID,
            attachmentID: attachmentID,
            command: command,
            requireExisting: requireExisting
        )
    }

    func resizeRemotePTY(sessionID: String, attachmentID: String, attachmentToken: String, cols: Int, rows: Int) throws {
        try remoteSurfaceCoordinator.resizeRemotePTY(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken,
            cols: cols,
            rows: rows
        )
    }

    func detachRemotePTYAttachment(sessionID: String, attachmentID: String, attachmentToken: String) throws {
        try remoteSurfaceCoordinator.detachRemotePTYAttachment(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken
        )
    }

    func remoteStatusPayload() -> [String: Any] {
        RemoteStatusSnapshot(
            configuration: remoteConfiguration,
            connectionState: remoteConnectionState,
            activeTerminalSessionCount: activeRemoteTerminalSessionCount,
            daemonStatus: remoteDaemonStatus,
            detectedPorts: remoteDetectedPorts,
            forwardedPorts: remoteForwardedPorts,
            portConflicts: remotePortConflicts,
            connectionDetail: remoteConnectionDetail,
            heartbeatCount: remoteHeartbeatCount,
            lastHeartbeatAt: remoteLastHeartbeatAt,
            proxyEndpoint: remoteProxyEndpoint,
            hasProxyOnlySidebarError: hasProxyOnlyRemoteSidebarError
        ).payload()
    }

    func configureRemoteConnection(_ configuration: WorkspaceRemoteConfiguration, autoConnect: Bool = true) {
        defer { TerminalController.shared.notifyRemotePTYControllerAvailabilityChanged() }
        let previousConfiguration = remoteConfiguration
        skipControlMasterCleanupAfterDetachedRemoteTransfer = false
        pendingRemoteDisconnectReplacement = nil
        let remoteDisconnectPlaceholderPanelIdsToClear = remoteDisconnectPlaceholderPanelIds
        if let previousConfiguration,
           previousConfiguration != configuration,
           !previousConfiguration.hasSamePersistentPTYIdentity(as: configuration) {
            remoteRelaySession.removeAllRemotePTYSessionIDs()
            endedPersistentRemotePTYAttachSurfaceIds.removeAll()
            clearRemoteRelayIDAliases()
        }
        remoteConfiguration = configuration
        seedInitialRemoteTerminalSessionIfNeeded(configuration: configuration)
        remoteDisconnectPlaceholderPanelIds.subtract(remoteDisconnectPlaceholderPanelIdsToClear)
        clearRemoteDetectedSurfacePorts()
        remoteDetectedPorts = []
        remoteForwardedPorts = []
        remotePortConflicts = []
        remoteProxyEndpoint = nil
        remoteHeartbeatCount = 0
        remoteLastHeartbeatAt = nil
        remoteConnectionDetail = nil
        remoteDaemonStatus = WorkspaceRemoteDaemonStatus()
        statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
        statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
        remoteLastErrorFingerprint = nil
        remoteLastDaemonErrorFingerprint = nil
        remoteLastPortConflictFingerprint = nil
        recomputeListeningPorts()

        let previousController = remoteSessionController
        activeRemoteSessionControllerID = nil
        remoteSessionController = nil
        previousController?.stop()
        applyRemoteProxyEndpointUpdate(nil)
        applyBrowserRemoteWorkspaceStatusToPanels()

        let foregroundAuthToken = Self.normalizedForegroundAuthToken(configuration.foregroundAuthToken)
        let shouldAutoConnect =
            autoConnect
            || (foregroundAuthToken != nil && foregroundAuthToken == pendingRemoteForegroundAuthToken)
        pendingRemoteForegroundAuthToken = nil
        if configuration.transport == .websocket,
           configuration.daemonWebSocketEndpoint == nil {
            remoteConnectionState = .connected
            applyBrowserRemoteWorkspaceStatusToPanels()
            return
        }
        guard shouldAutoConnect else {
            remoteConnectionState = .disconnected
            applyBrowserRemoteWorkspaceStatusToPanels()
            return
        }

        remoteConnectionState = .connecting
        applyBrowserRemoteWorkspaceStatusToPanels()
        let controllerID = UUID()
        var processRunner: any RemoteSessionProcessRunning = RemoteSessionProcessRunner()
#if DEBUG
        if let override = remoteSessionProcessRunnerOverrideForTesting {
            processRunner = override
        }
#endif
        let controller = RemoteSessionCoordinator(
            host: WorkspaceRemoteSessionHostAdapter(workspace: self, controllerID: controllerID),
            configuration: configuration,
            proxyBroker: TerminalController.shared.remoteProxyBroker,
            manifestRepository: RemoteDaemonManifestRepository(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            ),
            processRunner: processRunner,
            reachabilityProbe: RemoteHostReachabilityProbe(),
            relayCommandRewriter: WorkspaceRemoteRelayCommandRewriter(),
            buildInfo: WorkspaceRemoteSessionBuildInfo(),
            daemonStrings: RemoteDaemonStrings.appLocalized,
            strings: RemoteSessionStrings.appLocalized
        )
        activeRemoteSessionControllerID = controllerID
        remoteSessionController = controller
        controller.updateRemotePortScanningEnabled(Self.remotePortScanningEnabledFromSettings())
        syncRemotePortScanTTYs()
        syncRemoteRelayIDAliasesToController()
        controller.start()
    }

    func reconnectRemoteConnection(surfaceId: UUID? = nil) {
        guard let configuration = remoteConfiguration else { return }
        let reconnectingPlaceholderSurfaceId = surfaceId.flatMap { candidate -> UUID? in
            guard remoteDisconnectPlaceholderPanelIds.contains(candidate),
                  panels[candidate] is TerminalPanel else {
                return nil
            }
            return candidate
        }
        if let reconnectingPlaceholderSurfaceId {
            remoteDisconnectPlaceholderPanelIds.remove(reconnectingPlaceholderSurfaceId)
            trackRemoteTerminalSurface(reconnectingPlaceholderSurfaceId)
        }
        configureRemoteConnection(configuration, autoConnect: true)
    }

    private static func normalizedForegroundAuthToken(_ token: String?) -> String? {
        RemoteForegroundAuthToken().normalized(token)
    }

    func notifyRemoteForegroundAuthenticationReady(token: String? = nil) {
        guard let foregroundAuthToken = Self.normalizedForegroundAuthToken(token) else {
            return
        }

        guard let remoteConfiguration else {
            pendingRemoteForegroundAuthToken = foregroundAuthToken
            return
        }

        guard Self.normalizedForegroundAuthToken(remoteConfiguration.foregroundAuthToken) == foregroundAuthToken else {
            return
        }

        pendingRemoteForegroundAuthToken = nil
        guard remoteConnectionState == .disconnected else { return }
        reconnectRemoteConnection()
    }

    func disconnectRemoteConnection(clearConfiguration: Bool = false, disconnectedDetail: String? = nil) {
        defer { TerminalController.shared.notifyRemotePTYControllerAvailabilityChanged() }
        let shouldCleanupControlMaster =
            clearConfiguration
            && !isDetachingCloseTransaction
            && pendingDetachedSurfaces.isEmpty
            && !skipControlMasterCleanupAfterDetachedRemoteTransfer
        let configurationForCleanup = shouldCleanupControlMaster ? remoteConfiguration : nil
        let previousController = remoteSessionController
        activeRemoteSessionControllerID = nil
        remoteSessionController = nil
        previousController?.stop()
        pendingRemoteForegroundAuthToken = nil
        activeRemoteTerminalSurfaceIds.removeAll()
        endedPersistentRemotePTYAttachSurfaceIds.removeAll()
        activeRemoteTerminalSessionCount = 0
        pendingRemoteSurfaceTTYName = nil
        pendingRemoteSurfaceTTYSurfaceId = nil
        pendingRemoteSurfacePortKickReason = nil
        pendingRemoteSurfacePortKickSurfaceId = nil
        clearRemoteDetectedSurfacePorts()
        remoteDetectedPorts = []
        remoteForwardedPorts = []
        remotePortConflicts = []
        remoteProxyEndpoint = nil
        remoteHeartbeatCount = 0
        remoteLastHeartbeatAt = nil
        remoteConnectionState = .disconnected
        remoteConnectionDetail = disconnectedDetail
        remoteDaemonStatus = WorkspaceRemoteDaemonStatus()
        statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
        statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
        remoteLastErrorFingerprint = nil
        remoteLastDaemonErrorFingerprint = nil
        remoteLastPortConflictFingerprint = nil
        if clearConfiguration {
            remoteRelaySession.removeAllRemotePTYSessionIDs()
            endedPersistentRemotePTYAttachSurfaceIds.removeAll()
            clearRemoteRelayIDAliases()
            remoteConfiguration = nil
            pendingRemoteDisconnectReplacement = nil
            remoteDisconnectPlaceholderPanelIds.removeAll()
            skipControlMasterCleanupAfterDetachedRemoteTransfer = false
        }
        applyRemoteProxyEndpointUpdate(nil)
        applyBrowserRemoteWorkspaceStatusToPanels()
        recomputeListeningPorts()
        if let configurationForCleanup {
            Self.requestSSHControlMasterCleanupIfNeeded(configuration: configurationForCleanup)
        }
    }

    private func clearRemoteConfigurationIfWorkspaceBecameLocal() {
        guard !isDetachingCloseTransaction, panels.isEmpty, remoteConfiguration != nil else { return }
        guard pendingRemoteDisconnectReplacement == nil else { return }
        if remoteConfiguration?.preserveAfterTerminalExit == true {
            return
        }
        disconnectRemoteConnection(clearConfiguration: true)
    }

    private func seedInitialRemoteTerminalSessionIfNeeded(configuration: WorkspaceRemoteConfiguration) {
        guard configuration.terminalStartupCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        guard activeRemoteTerminalSurfaceIds.isEmpty else { return }
        let terminalIds = panels.compactMap { panelId, panel in
            panel is TerminalPanel && !remoteDisconnectPlaceholderPanelIds.contains(panelId)
                ? panelId
                : nil
        }
        if terminalIds.count == 1, let initialPanelId = terminalIds.first {
            trackRemoteTerminalSurface(initialPanelId)
            return
        }
        if let focusedPanelId, terminalIds.contains(focusedPanelId) {
            trackRemoteTerminalSurface(focusedPanelId)
        }
    }

    private func trackRemoteTerminalSurface(_ panelId: UUID) {
        skipControlMasterCleanupAfterDetachedRemoteTransfer = false
        endedPersistentRemotePTYAttachSurfaceIds.remove(panelId)
        pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
        transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: panelId)
        if remoteConfiguration?.preserveAfterTerminalExit == true,
           normalizedRemotePTYSessionID(remoteRelaySession.remotePTYSessionID(forPanel: panelId)) == nil {
            remoteRelaySession.setRemotePTYSessionID(Self.defaultSSHPTYSessionID(workspaceId: id, panelId: panelId), forPanel: panelId)
        }
        guard activeRemoteTerminalSurfaceIds.insert(panelId).inserted else { return }
        activeRemoteTerminalSessionCount = activeRemoteTerminalSurfaceIds.count
        applyPendingRemoteSurfaceTTYIfNeeded(to: panelId)
        _ = applyPendingRemoteSurfacePortKickIfNeeded(to: panelId)
    }

    func untrackRemoteTerminalSurface(_ panelId: UUID) {
        guard activeRemoteTerminalSurfaceIds.remove(panelId) != nil else { return }
        activeRemoteTerminalSessionCount = activeRemoteTerminalSurfaceIds.count
        guard !isDetachingCloseTransaction else { return }
        maybeDemoteRemoteWorkspaceAfterSSHSessionEnded()
    }

    /// App-side forwarder to ``SurfaceCreationCoordinator/sanitizedWorkspaceEnvironment(_:)``
    /// in `CmuxWorkspaces`, where the pure transform now lives. Kept as a
    /// `nonisolated static` so the existing call sites (the `init` paths and the
    /// nonisolated socket workspace-create path `v2WorkspaceCreate` in
    /// `TerminalController`) stay byte-identical. A fresh stateless coordinator is
    /// constructed because no instance exists in a static context; the
    /// coordinator's `nonisolated init` holds no state, so this is race-free off
    /// the main actor.
    nonisolated static func sanitizedWorkspaceEnvironment(_ environment: [String: String]) -> [String: String] {
        SurfaceCreationCoordinator().sanitizedWorkspaceEnvironment(environment)
    }

    /// App-side forwarder to ``SurfaceCreationCoordinator/startupEnvironment(workspaceEnvironment:overlaying:)``
    /// in `CmuxWorkspaces`, where the pure precedence-merge now lives. Kept
    /// `static` so the `init` path can call it before `self` is fully
    /// initialized; a fresh stateless coordinator is constructed because no
    /// instance is available in a static context.
    static func startupEnvironment(
        workspaceEnvironment: [String: String],
        overlaying explicit: [String: String]
    ) -> [String: String] {
        SurfaceCreationCoordinator().startupEnvironment(
            workspaceEnvironment: workspaceEnvironment,
            overlaying: explicit
        )
    }

    /// Instance convenience over ``SurfaceCreationCoordinator/startupEnvironment(workspaceEnvironment:overlaying:)``
    /// for the post-init surface-creation paths. Reuses the held
    /// ``surfaceCreation`` coordinator and the live `workspaceEnvironment`.
    func startupEnvironmentMergingWorkspaceEnvironment(_ explicit: [String: String]) -> [String: String] {
        surfaceCreation.startupEnvironment(workspaceEnvironment: workspaceEnvironment, overlaying: explicit)
    }

    private func terminalStartupEnvironment(
        base: [String: String],
        remoteStartupCommand: String?
    ) -> [String: String] {
        // The two live-state conditions (a remote command is in effect AND this
        // workspace has a remote SSH startup environment) stay here; the
        // value-typed overlay is the coordinator's
        // mergedStartupEnvironment(base:remoteEnvironment:).
        let remoteEnvironment = remoteStartupCommand == nil
            ? nil
            : remoteConfiguration?.sshTerminalStartupEnvironment
        return surfaceCreation.mergedStartupEnvironment(
            base: base,
            remoteEnvironment: remoteEnvironment
        )
    }

    private func normalizedRemotePTYSessionID(_ value: String?) -> String? {
        surfaceCreation.normalizedRemotePTYSessionID(value)
    }

    private func syncRemoteRelayIDAliasesToController() {
        remoteRelaySession.syncRemoteRelayIDAliasesToController()
    }

    private func clearRemoteRelayIDAliases() {
        remoteRelaySession.clearRemoteRelayIDAliases()
    }

    private func pruneRemoteRelaySurfaceAliases(validSurfaceIds: Set<UUID>) {
        remoteRelaySession.pruneRemoteRelaySurfaceAliases(validSurfaceIds: validSurfaceIds)
    }

    private func removeRemoteRelaySurfaceAliases(targeting panelId: UUID) {
        remoteRelaySession.removeRemoteRelaySurfaceAliases(targeting: panelId)
    }

    private func registerRemoteRelayIDAliases(
        snapshotWorkspaceId: UUID?,
        snapshotPanelId: UUID,
        restoredPanelId: UUID
    ) {
        remoteRelaySession.registerRemoteRelayIDAliases(
            snapshotWorkspaceId: snapshotWorkspaceId,
            snapshotPanelId: snapshotPanelId,
            restoredPanelId: restoredPanelId
        )
    }

    private func registerRemoteRelayIDAliases(remotePTYSessionID: String, restoredPanelId: UUID) {
        remoteRelaySession.registerRemoteRelayIDAliases(
            remotePTYSessionID: remotePTYSessionID,
            restoredPanelId: restoredPanelId
        )
    }

    /// Rewrites a relay command line using this workspace's current alias maps.
    /// Forwards to the held ``CmuxRemoteWorkspace/RemoteRelaySessionCoordinator``.
    func rewriteRemoteRelayCommandLine(_ commandLine: Data) -> Data {
        remoteRelaySession.rewriteRemoteRelayCommandLine(commandLine)
    }

    /// Alias-explicit relay-command rewrite. Forwards to
    /// ``CmuxRemoteWorkspace/RemoteRelayCommandLineRewriter``; retained as a
    /// `Workspace`-namespaced entry point for callers that pass alias maps
    /// directly (session-restore tests).
    nonisolated static func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        RemoteRelayCommandLineRewriter.rewrite(
            commandLine,
            workspaceAliases: workspaceAliases,
            surfaceAliases: surfaceAliases
        )
    }

    private func remotePTYSessionIDForSnapshot(panelId: UUID) -> String? {
        remoteRelaySession.remotePTYSessionIDForSnapshot(panelId: panelId)
    }

    /// Forwards to ``CmuxRemoteWorkspace/SSHPTYSessionID`` so the canonical
    /// `ssh-<workspace>-<panel>` formatting lives in the package value type;
    /// retained as a `Workspace`-namespaced entry point for internal callers
    /// and session-restore tests.
    nonisolated static func defaultSSHPTYSessionID(workspaceId: UUID, panelId: UUID) -> String {
        SSHPTYSessionID(workspaceId: workspaceId, panelId: panelId).rawValue
    }

    nonisolated static func sshPTYAttachStartupCommand(sessionID: String) -> String {
        SSHPTYAttachStartupCommandBuilder.command(sessionID: sessionID)
    }

    private func remotePTYAttachStartupCommand(sessionID: String) -> String {
        guard let remoteConfiguration,
              remoteConfiguration.preserveAfterTerminalExit,
              let foregroundAuthToken = remoteConfiguration.foregroundAuthToken else {
            return Self.sshPTYAttachStartupCommand(sessionID: sessionID)
        }
        let foregroundAuth = SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
            destination: remoteConfiguration.destination,
            port: remoteConfiguration.port,
            identityFile: remoteConfiguration.identityFile,
            sshOptions: remoteConfiguration.sshOptions,
            token: foregroundAuthToken
        )
        return SSHPTYAttachStartupCommandBuilder.command(
            sessionID: sessionID,
            foregroundAuth: foregroundAuth
        )
    }

    func discardRemotePTYSessionID(panelId: UUID) {
        remoteRelaySession.removeRemotePTYSessionID(forPanel: panelId)
        endedPersistentRemotePTYAttachSurfaceIds.remove(panelId)
        remoteRelaySession.removeRemoteRelaySurfaceAliases(targeting: panelId)
    }

    func remotePTYSessionIDMatches(panelId: UUID, sessionID: String?) -> Bool {
        remoteRelaySession.remotePTYSessionIDMatches(panelId: panelId, sessionID: sessionID)
    }

    @discardableResult
    func markRemotePTYAttachEnded(surfaceId: UUID, sessionID: String) -> (clearedRemotePTYSession: Bool, untrackedRemoteTerminal: Bool) {
        let normalizedSessionID = normalizedRemotePTYSessionID(sessionID)
        let expectedSessionID = normalizedRemotePTYSessionID(remoteRelaySession.remotePTYSessionID(forPanel: surfaceId))
            ?? Self.defaultSSHPTYSessionID(workspaceId: id, panelId: surfaceId)
        guard let normalizedSessionID, normalizedSessionID == expectedSessionID else {
            return (false, false)
        }

        let wasTracked = activeRemoteTerminalSurfaceIds.contains(surfaceId)
        if remoteConfiguration?.preserveAfterTerminalExit == true {
            endedPersistentRemotePTYAttachSurfaceIds.insert(surfaceId)
        } else {
            endedPersistentRemotePTYAttachSurfaceIds.remove(surfaceId)
        }
        remoteRelaySession.removeRemotePTYSessionID(forPanel: surfaceId)
        removeRemoteRelaySurfaceAliases(targeting: surfaceId)
        untrackRemoteTerminalSurface(surfaceId)
        return (true, wasTracked)
    }

    func markPersistentRemotePTYAttachFailed(surfaceId: UUID) {
        guard remoteConfiguration?.preserveAfterTerminalExit == true else { return }

        remoteRelaySession.removeRemotePTYSessionID(forPanel: surfaceId)
        endedPersistentRemotePTYAttachSurfaceIds.remove(surfaceId)
        removeRemoteRelaySurfaceAliases(targeting: surfaceId)
        pendingRemoteTerminalChildExitSurfaceIds.remove(surfaceId)
        transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: surfaceId)
        surfaceTTYNames.removeValue(forKey: surfaceId)
        if activeRemoteTerminalSurfaceIds.remove(surfaceId) != nil {
            activeRemoteTerminalSessionCount = activeRemoteTerminalSurfaceIds.count
        }
        syncRemotePortScanTTYs()
        applyBrowserRemoteWorkspaceStatusToPanels()
    }

    private func maybeDemoteRemoteWorkspaceAfterSSHSessionEnded() {
        guard activeRemoteTerminalSurfaceIds.isEmpty, remoteConfiguration != nil else { return }
        if remoteConfiguration?.preserveAfterTerminalExit == true {
            return
        }
        let hasBrowserPanels = panels.values.contains { $0 is BrowserPanel }
        if !hasBrowserPanels {
            if remoteConnectionState == .error ||
                remoteDaemonStatus.state == .error ||
                remoteConnectionState == .connecting ||
                remoteConnectionState == .reconnecting ||
                remoteConnectionState == .suspended {
                return
            }
            disconnectRemoteConnection(clearConfiguration: true)
        }
    }

    @MainActor
    func rememberPendingRemoteSurfaceTTY(_ ttyName: String, requestedSurfaceId: UUID?) {
        let trimmedTTY = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTTY.isEmpty else { return }
        pendingRemoteSurfaceTTYName = trimmedTTY
        pendingRemoteSurfaceTTYSurfaceId = requestedSurfaceId
    }

    @MainActor
    func rememberPendingRemoteSurfacePortKick(
        reason: PortScanKickReason,
        requestedSurfaceId: UUID?
    ) {
        pendingRemoteSurfacePortKickReason = reason
        pendingRemoteSurfacePortKickSurfaceId = requestedSurfaceId
    }

    @MainActor
    private func applyPendingRemoteSurfaceTTYIfNeeded(to panelId: UUID) {
        guard let ttyName = pendingRemoteSurfaceTTYName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ttyName.isEmpty else {
            return
        }
        if let requestedSurfaceId = pendingRemoteSurfaceTTYSurfaceId, requestedSurfaceId != panelId {
            return
        }
        surfaceTTYNames[panelId] = ttyName
        pendingRemoteSurfaceTTYName = nil
        pendingRemoteSurfaceTTYSurfaceId = nil
        syncRemotePortScanTTYs()
        if !applyPendingRemoteSurfacePortKickIfNeeded(to: panelId) {
            kickRemotePortScan(panelId: panelId, reason: .command)
        }
    }

    @MainActor
    @discardableResult
    func applyPendingRemoteSurfacePortKickIfNeeded(to panelId: UUID) -> Bool {
        guard let reason = pendingRemoteSurfacePortKickReason else {
            return false
        }
        if let requestedSurfaceId = pendingRemoteSurfacePortKickSurfaceId,
           requestedSurfaceId != panelId {
            return false
        }
        guard let ttyName = surfaceTTYNames[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ttyName.isEmpty else {
            return false
        }
        _ = ttyName
        pendingRemoteSurfacePortKickReason = nil
        pendingRemoteSurfacePortKickSurfaceId = nil
        kickRemotePortScan(panelId: panelId, reason: reason)
        return true
    }

    @MainActor
    func applyBootstrapRemoteTTY(_ ttyName: String) {
        let trimmedTTY = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTTY.isEmpty else { return }

        let candidateSurfaceId: UUID? = {
            if let focusedPanelId, activeRemoteTerminalSurfaceIds.contains(focusedPanelId) {
                return focusedPanelId
            }
            if activeRemoteTerminalSurfaceIds.count == 1 {
                return activeRemoteTerminalSurfaceIds.first
            }
            return nil
        }()

        guard let candidateSurfaceId else {
            rememberPendingRemoteSurfaceTTY(trimmedTTY, requestedSurfaceId: nil)
            return
        }

        surfaceTTYNames[candidateSurfaceId] = trimmedTTY
        syncRemotePortScanTTYs()
        if !applyPendingRemoteSurfacePortKickIfNeeded(to: candidateSurfaceId) {
            kickRemotePortScan(panelId: candidateSurfaceId, reason: .command)
        }
    }

    private func cleanupTransferredRemoteConnectionIfNeeded(surfaceId: UUID, relayPort: Int?) -> Bool {
        guard let relayPort,
              relayPort > 0,
              let cleanupConfiguration = transferredRemoteCleanupConfigurationsByPanelId[surfaceId],
              cleanupConfiguration.relayPort == relayPort else {
            return false
        }
        transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: surfaceId)
        Self.requestSSHControlMasterCleanupIfNeeded(configuration: cleanupConfiguration)
        return true
    }

    private func remoteTerminalSessionEndMatchesCurrentConfiguration(
        surfaceId: UUID,
        relayPort: Int?,
        configuration: WorkspaceRemoteConfiguration,
        allowUntracked: Bool
    ) -> Bool {
        guard activeRemoteTerminalSurfaceIds.contains(surfaceId) ||
            (allowUntracked && activeRemoteTerminalSurfaceIds.isEmpty) else {
            return false
        }
        if let relayPort, relayPort > 0 {
            return configuration.relayPort == relayPort
        }
        return true
    }

    private func disconnectRemoteConnectionAfterTerminalExit() {
        disconnectRemoteConnection(
            clearConfiguration: false,
            disconnectedDetail: String(
                localized: "remote.status.terminalDisconnected",
                defaultValue: "Remote terminal session disconnected"
            )
        )
    }

    func rememberPendingRemoteDisconnectReplacement(configuration: WorkspaceRemoteConfiguration) {
        let reconnectCommand = configuration.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        pendingRemoteDisconnectReplacement = PendingRemoteDisconnectReplacement(
            target: configuration.displayTarget,
            reconnectCommand: reconnectCommand?.isEmpty == false ? reconnectCommand : nil
        )
    }

    func markRemoteTerminalSessionEnded(surfaceId: UUID, relayPort: Int?, allowUntracked: Bool = false) {
        if cleanupTransferredRemoteConnectionIfNeeded(surfaceId: surfaceId, relayPort: relayPort) {
            return
        }
        guard let configuration = remoteConfiguration,
              remoteTerminalSessionEndMatchesCurrentConfiguration(
                surfaceId: surfaceId,
                relayPort: relayPort,
                configuration: configuration,
                allowUntracked: allowUntracked
              ) else {
            return
        }
        let preservesRemotePTYSession = configuration.preserveAfterTerminalExit
        if !preservesRemotePTYSession {
            rememberPendingRemoteDisconnectReplacement(configuration: configuration)
        }
        pendingRemoteTerminalChildExitSurfaceIds.insert(surfaceId)
        if activeRemoteTerminalSurfaceIds.remove(surfaceId) != nil {
            activeRemoteTerminalSessionCount = activeRemoteTerminalSurfaceIds.count
        }
        if activeRemoteTerminalSurfaceIds.isEmpty {
            guard !preservesRemotePTYSession else { return }
            let shouldCleanupControlMaster =
                configuration.relayPort != nil &&
                configuration.transport == .ssh &&
                !isDetachingCloseTransaction &&
                pendingDetachedSurfaces.isEmpty &&
                !skipControlMasterCleanupAfterDetachedRemoteTransfer
            disconnectRemoteConnectionAfterTerminalExit()
            if shouldCleanupControlMaster {
                Self.requestSSHControlMasterCleanupIfNeeded(configuration: configuration)
            }
        }
    }

    func teardownRemoteConnection() {
        disconnectRemoteConnection(clearConfiguration: true)
    }

    static func requestSSHControlMasterCleanupIfNeeded(configuration: WorkspaceRemoteConfiguration) {
        guard let arguments = RemoteControlMasterCleanup().cleanupArguments(configuration: configuration) else { return }
        SSHControlMasterCleanupService().requestCleanup(
            arguments: arguments,
            environment: configuration.sshProcessEnvironment
        )
    }


    func applyRemoteConnectionStateUpdate(
        _ state: WorkspaceRemoteConnectionState,
        detail: String?,
        target: String
    ) {
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxyOnlyError = trimmedDetail.map(\.indicatesProxyOnlyRemoteError) ?? false
        let effectiveState = state.effectiveRemoteConnectionState(
            isProxyOnlyError: proxyOnlyError,
            preservesProxyFailureWhileSSHTerminalIsAlive: preservesProxyFailureWhileSSHTerminalIsAlive,
            hasProxyOnlySidebarError: hasProxyOnlyRemoteSidebarError
        )

        remoteConnectionState = effectiveState
        remoteConnectionDetail = detail
        applyBrowserRemoteWorkspaceStatusToPanels()

        if state == .suspended {
            let entryDetail = trimmedDetail ?? ""
            let entryValue = String(
                format: String(
                    localized: "remote.statusEntry.suspended",
                    defaultValue: "SSH reconnect paused (%@): %@"
                ),
                locale: .current,
                target,
                entryDetail
            )
            statusEntries[Self.remoteErrorStatusKey] = SidebarStatusEntry(
                key: Self.remoteErrorStatusKey,
                value: entryValue,
                icon: "pause.circle",
                color: nil,
                timestamp: Date()
            )
            let fingerprint = "suspended:\(entryDetail)"
            if remoteLastErrorFingerprint != fingerprint {
                remoteLastErrorFingerprint = fingerprint
                appendSidebarLog(message: entryValue, level: .warning, source: "remote")
                hostEnvironment?.notificationStore?.addNotification(
                    tabId: id,
                    surfaceId: nil,
                    title: String(
                        localized: "remote.notification.suspendedTitle",
                        defaultValue: "SSH Reconnect Paused"
                    ),
                    subtitle: target,
                    body: entryDetail,
                    cooldownKey: remoteNotificationCooldownKey(target: target),
                    cooldownInterval: Self.remoteNotificationCooldown
                )
            }
            return
        }

        if let trimmedDetail, !trimmedDetail.isEmpty, (state == .error || proxyOnlyError) {
            let statusPrefix = proxyOnlyError ? "Remote proxy unavailable" : "SSH error"
            let statusIcon = proxyOnlyError ? "exclamationmark.triangle.fill" : "network.slash"
            let notificationTitle = proxyOnlyError ? "Remote Proxy Unavailable" : "Remote SSH Error"
            let logSource = proxyOnlyError ? "remote-proxy" : "remote"
            statusEntries[Self.remoteErrorStatusKey] = SidebarStatusEntry(
                key: Self.remoteErrorStatusKey,
                value: "\(statusPrefix) (\(target)): \(trimmedDetail)",
                icon: statusIcon,
                color: nil,
                timestamp: Date()
            )

            let fingerprint = "connection:\(trimmedDetail)"
            if remoteLastErrorFingerprint != fingerprint {
                remoteLastErrorFingerprint = fingerprint
                appendSidebarLog(
                    message: "\(statusPrefix) (\(target)): \(trimmedDetail)",
                    level: .error,
                    source: logSource
                )
                hostEnvironment?.notificationStore?.addNotification(
                    tabId: id,
                    surfaceId: nil,
                    title: notificationTitle,
                    subtitle: target,
                    body: trimmedDetail,
                    cooldownKey: remoteNotificationCooldownKey(target: target),
                    cooldownInterval: Self.remoteNotificationCooldown
                )
            }
            return
        }

        if state == .connected {
            statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
            remoteLastErrorFingerprint = nil
        }
    }

    func applyRemoteDaemonStatusUpdate(_ status: WorkspaceRemoteDaemonStatus, target: String) {
        remoteDaemonStatus = status
        applyBrowserRemoteWorkspaceStatusToPanels()
        guard status.state == .error else {
            remoteLastDaemonErrorFingerprint = nil
            return
        }
        let trimmedDetail = status.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "remote daemon error"
        let fingerprint = "daemon:\(trimmedDetail)"
        guard remoteLastDaemonErrorFingerprint != fingerprint else { return }
        remoteLastDaemonErrorFingerprint = fingerprint
        appendSidebarLog(
            message: "Remote daemon error (\(target)): \(trimmedDetail)",
            level: .error,
            source: "remote-daemon"
        )
    }

    func applyRemoteProxyEndpointUpdate(_ endpoint: BrowserProxyEndpoint?) {
        remoteProxyEndpoint = endpoint
        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            browserPanel.setRemoteProxyEndpoint(endpoint)
        }
        applyBrowserRemoteWorkspaceStatusToPanels()
    }

    func applyRemoteHeartbeatUpdate(count: Int, lastSeenAt: Date?) {
        remoteHeartbeatCount = max(0, count)
        remoteLastHeartbeatAt = lastSeenAt
        applyBrowserRemoteWorkspaceStatusToPanels()
    }

    func applyRemoteDetectedSurfacePortsSnapshot(
        detectedByPanel: [UUID: [Int]],
        detected: [Int],
        forwarded: [Int],
        conflicts: [Int],
        target: String
    ) {
        let trackedSurfaceIds = Set(detectedByPanel.keys)
        for panelId in remoteDetectedSurfaceIds.subtracting(trackedSurfaceIds) {
            surfaceListeningPorts.removeValue(forKey: panelId)
        }
        remoteDetectedSurfaceIds = trackedSurfaceIds

        for (panelId, ports) in detectedByPanel {
            if ports.isEmpty {
                surfaceListeningPorts.removeValue(forKey: panelId)
            } else {
                surfaceListeningPorts[panelId] = ports
            }
        }

        remoteDetectedPorts = detected
        remoteForwardedPorts = forwarded
        remotePortConflicts = conflicts
        recomputeListeningPorts()

        if conflicts.isEmpty {
            statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
            remoteLastPortConflictFingerprint = nil
            return
        }

        let conflictsList = conflicts.map { ":\($0)" }.joined(separator: ", ")
        statusEntries[Self.remotePortConflictStatusKey] = SidebarStatusEntry(
            key: Self.remotePortConflictStatusKey,
            value: "SSH port conflicts (\(target)): \(conflictsList)",
            icon: "exclamationmark.triangle.fill",
            color: nil,
            timestamp: Date()
        )

        let fingerprint = conflicts.map(String.init).joined(separator: ",")
        guard remoteLastPortConflictFingerprint != fingerprint else { return }
        remoteLastPortConflictFingerprint = fingerprint
        appendSidebarLog(
            message: "Port conflicts while forwarding \(target): \(conflictsList)",
            level: .warning,
            source: "remote-forward"
        )
    }

    private func clearRemoteDetectedSurfacePorts() {
        for panelId in remoteDetectedSurfaceIds {
            surfaceListeningPorts.removeValue(forKey: panelId)
        }
        remoteDetectedSurfaceIds.removeAll()
    }

    private func appendSidebarLog(message: String, level: SidebarLogLevel, source: String?) {
        sidebarMetadata.appendLogEntry(message: message, level: level, source: source)
    }

    // MARK: - Panel Operations

    private func seedTerminalInheritanceFontPoints(
        panelId: UUID,
        configTemplate: CmuxSurfaceConfigTemplate?
    ) {
        guard let fontPoints = configTemplate?.fontSize, fontPoints > 0 else { return }
        terminalInheritanceFontPointsByPanelId[panelId] = fontPoints
        lastTerminalConfigInheritanceFontPoints = fontPoints
    }

    private func rememberTerminalConfigInheritanceSource(_ terminalPanel: TerminalPanel) {
        lastTerminalConfigInheritancePanelId = terminalPanel.id
        if let sourceSurface = terminalPanel.surface.surface,
           let runtimePoints = cmuxCurrentSurfaceFontSizePoints(sourceSurface) {
            let existing = terminalInheritanceFontPointsByPanelId[terminalPanel.id]
            if existing == nil || abs((existing ?? runtimePoints) - runtimePoints) > 0.05 {
                terminalInheritanceFontPointsByPanelId[terminalPanel.id] = runtimePoints
            }
            lastTerminalConfigInheritanceFontPoints =
                terminalInheritanceFontPointsByPanelId[terminalPanel.id] ?? runtimePoints
        }
    }

    func lastRememberedTerminalPanelForConfigInheritance() -> TerminalPanel? {
        guard let panelId = lastTerminalConfigInheritancePanelId else { return nil }
        return terminalPanel(for: panelId)
    }

    func lastRememberedTerminalFontPointsForConfigInheritance() -> Float? {
        lastTerminalConfigInheritanceFontPoints
    }

    private func resolvedTerminalStartupWorkingDirectory(
        requestedWorkingDirectory: String?,
        sourcePanelId: UUID?
    ) -> String? {
        surfaceCreation.resolvedStartupWorkingDirectory(candidates: [
            requestedWorkingDirectory,
            sourcePanelId.flatMap { panelDirectories[$0] },
            sourcePanelId.flatMap { terminalPanel(for: $0)?.requestedWorkingDirectory },
            currentDirectory,
        ])
    }

    /// Candidate terminal panels used as the source when creating inherited Ghostty config.
    /// Preference order:
    /// 1) explicitly preferred terminal panel (when the caller has one),
    /// 2) selected terminal in the target pane,
    /// 3) currently focused terminal in the workspace,
    /// 4) last remembered terminal source,
    /// 5) first terminal tab in the target pane,
    /// 6) deterministic workspace fallback.
    private func terminalPanelConfigInheritanceCandidates(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> [TerminalPanel] {
        var candidates: [TerminalPanel] = []
        var seen: Set<UUID> = []

        func appendCandidate(_ panel: TerminalPanel?) {
            guard let panel, seen.insert(panel.id).inserted else { return }
            candidates.append(panel)
        }

        if let preferredPanelId,
           let terminalPanel = terminalPanel(for: preferredPanelId) {
            appendCandidate(terminalPanel)
        }

        if let preferredPaneId,
           let selectedSurfaceId = bonsplitController.selectedTab(inPane: preferredPaneId)?.id,
           let selectedPanelId = panelIdFromSurfaceId(selectedSurfaceId),
           let selectedTerminalPanel = terminalPanel(for: selectedPanelId) {
            appendCandidate(selectedTerminalPanel)
        }

        if let focusedTerminalPanel {
            appendCandidate(focusedTerminalPanel)
        }

        if let rememberedTerminalPanel = lastRememberedTerminalPanelForConfigInheritance() {
            appendCandidate(rememberedTerminalPanel)
        }

        if let preferredPaneId {
            for tab in bonsplitController.tabs(inPane: preferredPaneId) {
                guard let panelId = panelIdFromSurfaceId(tab.id),
                      let terminalPanel = terminalPanel(for: panelId) else { continue }
                appendCandidate(terminalPanel)
            }
        }

        for terminalPanel in panels.values
            .compactMap({ $0 as? TerminalPanel })
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            appendCandidate(terminalPanel)
        }

        return candidates
    }

    /// Picks the first terminal panel candidate used as the inheritance source.
    func terminalPanelForConfigInheritance(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> TerminalPanel? {
        terminalPanelConfigInheritanceCandidates(
            preferredPanelId: preferredPanelId,
            inPane: preferredPaneId
        ).first
    }

    private func inheritedTerminalConfig(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> CmuxSurfaceConfigTemplate? {
        surfaceCreation.resolveInheritedConfig(
            host: self,
            preferredPanelId: preferredPanelId,
            inPane: preferredPaneId
        )
    }

    /// Create a new split with a terminal panel
    @discardableResult
    func newTerminalSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        focus: Bool = true,
        workingDirectory: String? = nil,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        startupEnvironment: [String: String] = [:],
        initialDividerPosition: CGFloat? = nil,
        remotePTYSessionID: String? = nil
    ) -> TerminalPanel? {
        return newTerminalSplitOutcome(
            from: panelId,
            orientation: orientation,
            insertFirst: insertFirst,
            focus: focus,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            startupEnvironment: startupEnvironment,
            initialDividerPosition: initialDividerPosition,
            remotePTYSessionID: remotePTYSessionID
        ).panel
    }

    /// Like ``newTerminalSplit(from:orientation:insertFirst:focus:workingDirectory:initialCommand:tmuxStartCommand:startupEnvironment:initialDividerPosition:remotePTYSessionID:)``
    /// but distinguishes a split routed to the remote tmux mirror from a genuine
    /// failure, so socket/CLI handlers can report the routed request as accepted.
    /// (Reporting an error makes automation retry and duplicate remote panes.)
    func newTerminalSplitOutcome(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        focus: Bool = true,
        workingDirectory: String? = nil,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        startupEnvironment: [String: String] = [:],
        initialDividerPosition: CGFloat? = nil,
        remotePTYSessionID: String? = nil
    ) -> TerminalPanelCreationOutcome {
        // In a remote tmux mirror workspace a split means "split the mirrored
        // tmux pane": route it to the remote and let the resulting
        // %layout-change render the new pane (one source of truth). NEVER
        // create a local split here, even when the route can't be taken
        // (dead/missing connection) — a local pane would be an orphan the
        // mirror's rebuild() never reconciles, breaking the 1:1 invariant
        // (same rule as newTerminalSurfaceOutcome). Routing by the requested
        // panel — not the pane's selected tab, which is all the bonsplit-level
        // veto in splitTabBar(_:shouldSplitPane:orientation:) can see — keeps
        // programmatic splits aimed at a background window-tab precise.
        if isRemoteTmuxMirror {
            let routed = hostEnvironment?.remoteTmuxController.handleMirrorTabSplitRequested(
                workspaceId: id,
                panelId: panelId,
                vertical: orientation == .vertical
            ) ?? false
            return routed ? .routedToRemote : .failed
        }
        guard let panel = newTerminalSplitLocal(
            from: panelId,
            orientation: orientation,
            insertFirst: insertFirst,
            focus: focus,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            startupEnvironment: startupEnvironment,
            initialDividerPosition: initialDividerPosition,
            remotePTYSessionID: remotePTYSessionID
        ) else { return .failed }
        return .created(panel)
    }

    private func newTerminalSplitLocal(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        focus: Bool,
        workingDirectory: String?,
        initialCommand: String?,
        tmuxStartCommand: String?,
        startupEnvironment: [String: String],
        initialDividerPosition: CGFloat?,
        remotePTYSessionID: String?
    ) -> TerminalPanel? {
#if DEBUG
        let splitTimingStart = ProcessInfo.processInfo.systemUptime
        let splitTransport = remoteConfiguration?.transport.rawValue ?? "local"
        dlog(
            "split.timing workspace=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "transport=\(splitTransport) stage=start elapsedMs=0.00"
        )
#endif
        // Find the pane containing the source panel (the SurfaceLifecycleCoordinator
        // owns this resolution: surfaceId(forPanelId:) then the allPaneIds.first scan).
        guard let paneId = paneId(forPanelId: panelId) else { return nil }
        var inheritedConfig = inheritedTerminalConfig(preferredPanelId: panelId, inPane: paneId)
        let explicitInitialCommand = surfaceCreation.normalizedExplicitInitialCommand(initialCommand)
        let remoteTerminalStartupCommand = remoteTerminalStartupCommand()
        let startupCommandResolution = surfaceCreation.resolveStartupCommand(
            explicitCommand: explicitInitialCommand,
            remoteCommand: remoteTerminalStartupCommand
        )
        let startupCommand = startupCommandResolution.startupCommand
        let remoteStartupCommandForEnvironment = startupCommandResolution.remoteCommandForEnvironment
        let effectiveStartupEnvironment = terminalStartupEnvironment(
            base: startupEnvironmentMergingWorkspaceEnvironment(startupEnvironment),
            remoteStartupCommand: remoteStartupCommandForEnvironment
        )
        // Hold the pane open after the remote session ends so the user can read the
        // "ssh exited …" message the startup script prints. Otherwise Ghostty silently
        // respawns a local login shell when the command exits (the PTY falls through
        // to $SHELL), and a dead VM looks identical to a healthy workspace with a
        // local prompt — which is what we saw during dogfood.
        inheritedConfig = surfaceCreation.configHoldingPaneAfterStartupCommand(
            inheritedConfig: inheritedConfig,
            hasStartupCommand: startupCommand != nil
        )
#if DEBUG
        dlog(
            "split.timing workspace=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "transport=\(splitTransport) stage=command_resolved elapsedMs=\(debugElapsedMs(since: splitTimingStart)) " +
            "remoteCommand=\(remoteTerminalStartupCommand == nil ? 0 : 1)"
        )
#endif

        // Resolve cwd as explicit request, source reported cwd, source requested
        // startup cwd, then workspace currentDirectory.
        let splitWorkingDirectory = resolvedTerminalStartupWorkingDirectory(
            requestedWorkingDirectory: workingDirectory,
            sourcePanelId: panelId
        )
#if DEBUG
        cmuxDebugLog(
            "split.cwd panelId=\(panelId.uuidString.prefix(5)) panelDir=\(panelDirectories[panelId] ?? "nil") requestedDir=\(terminalPanel(for: panelId)?.requestedWorkingDirectory ?? "nil") currentDir=\(currentDirectory) resolved=\(splitWorkingDirectory ?? "nil")"
        )
#endif

        // Create the new terminal panel.
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: splitWorkingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: startupCommand,
            tmuxStartCommand: tmuxStartCommand,
            additionalEnvironment: effectiveStartupEnvironment
        )
        configureNewTerminalPanel(newPanel)
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        let normalizedRemotePTYSessionID = normalizedRemotePTYSessionID(remotePTYSessionID)
        let tracksRemoteTerminalSurface = surfaceCreation.tracksRemoteTerminalSurface(remoteStartupCommand: remoteTerminalStartupCommand, normalizedRemotePTYSessionID: normalizedRemotePTYSessionID)
        if let normalizedRemotePTYSessionID {
            remoteRelaySession.setRemotePTYSessionID(normalizedRemotePTYSessionID, forPanel: newPanel.id)
            registerRemoteRelayIDAliases(remotePTYSessionID: normalizedRemotePTYSessionID, restoredPanelId: newPanel.id)
        }
        if tracksRemoteTerminalSurface {
            trackRemoteTerminalSurface(newPanel.id)
        }
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)
#if DEBUG
        dlog(
            "split.timing workspace=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "transport=\(splitTransport) stage=panel_ready elapsedMs=\(debugElapsedMs(since: splitTimingStart)) " +
            "newPanel=\(newPanel.id.uuidString.prefix(5))"
        )
#endif

        // Pre-generate the bonsplit tab ID so we can install the panel mapping before bonsplit
        // mutates layout state (avoids transient "Empty Panel" flashes during split).
        let newTab = Bonsplit.Tab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal.rawValue,
            isDirty: newPanel.isDirty,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = newPanel.id
        let previousFocusedPanelId = focusedPanelId

        // Capture the source terminal's hosted view before bonsplit mutates focusedPaneId,
        // so we can hand it to focusPanel as the "move focus FROM" view.
        let previousHostedView = focusedTerminalPanel?.hostedView

        // Create the split with the new tab already present in the new pane.
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            remoteRelaySession.removeRemotePTYSessionID(forPanel: newPanel.id)
            removeRemoteRelaySurfaceAliases(targeting: newPanel.id)
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            if tracksRemoteTerminalSurface {
                untrackRemoteTerminalSurface(newPanel.id)
            }
            terminalInheritanceFontPointsByPanelId.removeValue(forKey: newPanel.id)
            return nil
        }
        applyInitialSplitDividerPosition(initialDividerPosition, sourcePaneId: paneId, newPaneId: newPaneId)
        publishCmuxSplitCreated(newPaneId, sourcePaneId: paneId, orientation: orientation, surfaceId: newPanel.id, kind: "terminal", origin: "terminal_split", focused: focus)

#if DEBUG
        cmuxDebugLog("split.created pane=\(paneId.id.uuidString.prefix(5)) orientation=\(orientation)")
        cmuxDebugLog(
            "split.timing workspace=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "transport=\(splitTransport) stage=layout_committed elapsedMs=\(debugElapsedMs(since: splitTimingStart)) " +
            "newPanel=\(newPanel.id.uuidString.prefix(5))"
        )
#endif

        // Suppress the old view's becomeFirstResponder side-effects during SwiftUI reparenting.
        // Without this, reparenting triggers onFocus + ghostty_surface_set_focus on the old view,
        // stealing focus from the new panel and creating model/surface divergence.
        if focus {
            suppressReparentFocusUntilLayoutFollowUp(
                previousHostedView,
                reason: "workspace.terminalSplitReparent"
            )
            focusPanel(newPanel.id, previousHostedView: previousHostedView)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: newPanel.id,
                previousHostedView: previousHostedView
            )
        }
#if DEBUG
        dlog(
            "split.timing workspace=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "transport=\(splitTransport) stage=focus_scheduled elapsedMs=\(debugElapsedMs(since: splitTimingStart)) " +
            "newPanel=\(newPanel.id.uuidString.prefix(5)) focus=\(focus ? 1 : 0)"
        )
#endif

        owningTabManager?.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: id,
            panelId: newPanel.id,
            reason: "splitCreate"
        )

        return newPanel
    }

    /// Create a new surface (nested tab) in the specified pane with a terminal panel.
    /// - Parameter focus: nil = focus only if the target pane is already focused (default UI behavior),
    ///                    true = force focus/selection of the new surface,
    ///                    false = never focus (used for internal placeholder repair paths).
    @discardableResult
    func newTerminalSurface(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        workingDirectory: String? = nil,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        initialInput: String? = nil,
        startupEnvironment: [String: String] = [:],
        runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy = .immediate,
        autoRefreshMetadata: Bool = true,
        preserveFocusWhenUnfocused: Bool = true,
        remotePTYSessionID: String? = nil,
        suppressWorkspaceRemoteStartupCommand: Bool = false,
        restoredSurfaceId: UUID? = nil,
        inheritWorkingDirectoryFallback: Bool = false,
        workingDirectoryFallbackSourcePanelId: UUID? = nil
    ) -> TerminalPanel? {
        return newTerminalSurfaceOutcome(
            inPane: paneId,
            focus: focus,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialInput: initialInput,
            startupEnvironment: startupEnvironment,
            runtimeSpawnPolicy: runtimeSpawnPolicy,
            autoRefreshMetadata: autoRefreshMetadata,
            preserveFocusWhenUnfocused: preserveFocusWhenUnfocused,
            remotePTYSessionID: remotePTYSessionID,
            suppressWorkspaceRemoteStartupCommand: suppressWorkspaceRemoteStartupCommand,
            restoredSurfaceId: restoredSurfaceId,
            inheritWorkingDirectoryFallback: inheritWorkingDirectoryFallback,
            workingDirectoryFallbackSourcePanelId: workingDirectoryFallbackSourcePanelId
        ).panel
    }

    /// Like ``newTerminalSurface(inPane:focus:workingDirectory:initialCommand:tmuxStartCommand:initialInput:startupEnvironment:autoRefreshMetadata:preserveFocusWhenUnfocused:remotePTYSessionID:suppressWorkspaceRemoteStartupCommand:)``
    /// but distinguishes a request routed to the remote tmux mirror from a genuine
    /// failure, so socket/CLI handlers can report the routed request as accepted.
    func newTerminalSurfaceOutcome(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        workingDirectory: String? = nil,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        initialInput: String? = nil,
        startupEnvironment: [String: String] = [:],
        runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy = .immediate,
        autoRefreshMetadata: Bool = true,
        preserveFocusWhenUnfocused: Bool = true,
        remotePTYSessionID: String? = nil,
        suppressWorkspaceRemoteStartupCommand: Bool = false,
        restoredSurfaceId: UUID? = nil,
        inheritWorkingDirectoryFallback: Bool = false,
        workingDirectoryFallbackSourcePanelId: UUID? = nil
    ) -> TerminalPanelCreationOutcome {
        // In a remote tmux mirror workspace, a new tab means "create a tmux
        // window" — route it to the remote and let the resulting %window-add
        // notification add the tab (one source of truth). NEVER create a local
        // terminal here, even when the remote route can't be taken (dead/missing
        // connection): a local tab would be an orphan the mirror can't reconcile,
        // breaking the 1:1 invariant (symmetric with newBrowserSurface). A dead
        // mirror workspace is torn down separately via handleSessionEndedRemotely.
        if isRemoteTmuxMirror {
            let routed = hostEnvironment?.remoteTmuxController
                .handleMirrorNewTabRequested(workspaceId: id) ?? false
            return routed ? .routedToRemote : .failed
        }
        guard let panel = newTerminalSurfaceLocal(
            inPane: paneId,
            focus: focus,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialInput: initialInput,
            startupEnvironment: startupEnvironment,
            runtimeSpawnPolicy: runtimeSpawnPolicy,
            autoRefreshMetadata: autoRefreshMetadata,
            preserveFocusWhenUnfocused: preserveFocusWhenUnfocused,
            remotePTYSessionID: remotePTYSessionID,
            suppressWorkspaceRemoteStartupCommand: suppressWorkspaceRemoteStartupCommand,
            restoredSurfaceId: restoredSurfaceId,
            inheritWorkingDirectoryFallback: inheritWorkingDirectoryFallback,
            workingDirectoryFallbackSourcePanelId: workingDirectoryFallbackSourcePanelId
        ) else { return .failed }
        return .created(panel)
    }

    private func newTerminalSurfaceLocal(
        inPane paneId: PaneID,
        focus: Bool?,
        workingDirectory: String?,
        initialCommand: String?,
        tmuxStartCommand: String?,
        initialInput: String?,
        startupEnvironment: [String: String],
        runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy,
        autoRefreshMetadata: Bool,
        preserveFocusWhenUnfocused: Bool,
        remotePTYSessionID: String?,
        suppressWorkspaceRemoteStartupCommand: Bool,
        restoredSurfaceId: UUID?,
        inheritWorkingDirectoryFallback: Bool,
        workingDirectoryFallbackSourcePanelId: UUID?
    ) -> TerminalPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        var inheritedConfig = inheritedTerminalConfig(inPane: paneId)
        let explicitInitialCommand = surfaceCreation.normalizedExplicitInitialCommand(initialCommand)
        let remoteTerminalStartupCommand = suppressWorkspaceRemoteStartupCommand ? nil : remoteTerminalStartupCommand()
        let startupCommandResolution = surfaceCreation.resolveStartupCommand(
            explicitCommand: explicitInitialCommand,
            remoteCommand: remoteTerminalStartupCommand
        )
        let startupCommand = startupCommandResolution.startupCommand
        let remoteStartupCommandForEnvironment = startupCommandResolution.remoteCommandForEnvironment
        let effectiveStartupEnvironment = terminalStartupEnvironment(
            base: startupEnvironmentMergingWorkspaceEnvironment(startupEnvironment),
            remoteStartupCommand: remoteStartupCommandForEnvironment
        )
        // See the comment at the other call site: hold the PTY open after the remote
        // command exits so the user sees the error rather than a silently-respawned
        // local login shell.
        inheritedConfig = surfaceCreation.configHoldingPaneAfterStartupCommand(
            inheritedConfig: inheritedConfig,
            hasStartupCommand: startupCommand != nil
        )
        let fallbackSourcePanelId = workingDirectoryFallbackSourcePanelId
            ?? bonsplitController.selectedTab(inPane: paneId).map(\.id).flatMap(panelIdFromSurfaceId)
        let requestedWorkingDirectory = inheritWorkingDirectoryFallback && startupCommand == nil
            ? resolvedTerminalStartupWorkingDirectory(
                requestedWorkingDirectory: workingDirectory,
                sourcePanelId: fallbackSourcePanelId
            )
            : workingDirectory

        // Create new terminal panel. A restored panel reuses its persisted
        // surface id (the panel/surface id IS the ghostty surface id, a
        // Swift-side UUID), so a session's terminal binding survives relaunch
        // and restore. The caller only passes an id it has verified is free.
        let newPanel = TerminalPanel(
            id: restoredSurfaceId ?? UUID(),
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: requestedWorkingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: startupCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialInput: initialInput,
            additionalEnvironment: effectiveStartupEnvironment,
            runtimeSpawnPolicy: runtimeSpawnPolicy
        )
        configureNewTerminalPanel(newPanel)
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        let normalizedRemotePTYSessionID = normalizedRemotePTYSessionID(remotePTYSessionID)
        let tracksRemoteTerminalSurface = surfaceCreation.tracksRemoteTerminalSurface(remoteStartupCommand: remoteTerminalStartupCommand, normalizedRemotePTYSessionID: normalizedRemotePTYSessionID)
        if let normalizedRemotePTYSessionID {
            remoteRelaySession.setRemotePTYSessionID(normalizedRemotePTYSessionID, forPanel: newPanel.id)
            registerRemoteRelayIDAliases(remotePTYSessionID: normalizedRemotePTYSessionID, restoredPanelId: newPanel.id)
        }
        if tracksRemoteTerminalSurface {
            trackRemoteTerminalSurface(newPanel.id)
        }
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)

        // Create tab in bonsplit
        guard let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal.rawValue,
            isDirty: newPanel.isDirty,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            remoteRelaySession.removeRemotePTYSessionID(forPanel: newPanel.id)
            removeRemoteRelaySurfaceAliases(targeting: newPanel.id)
            if tracksRemoteTerminalSurface {
                untrackRemoteTerminalSurface(newPanel.id)
            }
            terminalInheritanceFontPointsByPanelId.removeValue(forKey: newPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = newPanel.id
        publishCmuxSurfaceCreated(newPanel.id, paneId: paneId, kind: "terminal", origin: "terminal_tab", focused: shouldFocusNewTab)

        // bonsplit's createTab may not reliably emit didSelectTab, and its internal selection
        // updates can be deferred. Force a deterministic selection + focus path so the new
        // surface becomes interactive immediately (no "frozen until pane switch" state).
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            newPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else if preserveFocusWhenUnfocused || owningTabManager?.selectedTabId == id {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: newPanel.id,
                previousHostedView: previousHostedView
            )
        } else {
            clearNonFocusSplitFocusReassert()
        }

        if autoRefreshMetadata {
            owningTabManager?.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: id,
                panelId: newPanel.id,
                reason: "surfaceCreate"
            )
        }
        return newPanel
    }

    /// Creates a configured MANUAL-I/O ``TerminalPanel`` for one remote tmux pane,
    /// WITHOUT inserting it into the workspace's bonsplit/`panels` (the
    /// ``RemoteTmuxWindowMirror`` owns it and renders it via ``TerminalPanelView``
    /// inside a single tab, so the pane gets the full native cmux pane chrome —
    /// background, focus overlay, dividers).
    func makeRemoteTmuxPanePanel(onInput: @escaping @Sendable (Data) -> Void) -> TerminalPanel {
        let surface = TerminalSurface(
            tabId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            manualIO: true,
            manualInputHandler: onInput
        )
        let panel = TerminalPanel(workspaceId: id, surface: surface)
        configureNewTerminalPanel(panel)
        return panel
    }

    /// Mounts a remote tmux pane as a live display tab in this workspace.
    ///
    /// The tab is backed by a MANUAL-I/O ``TerminalSurface`` (no local process):
    /// the caller feeds `%output` via ``TerminalSurface/processRemoteOutput(_:)``
    /// and receives typed input through `onInput` (→ tmux `send-keys`). Used by
    /// ``RemoteTmuxController`` to render a mirrored remote tmux pane.
    ///
    /// - Parameter focus: when `true`, selects and reasserts AppKit keyboard
    ///   focus onto the created tab (a user-initiated attach). When `false`
    ///   (socket/background mirroring), the tab is created and selected within
    ///   its pane but the user's keyboard focus is left untouched, per the
    ///   socket focus policy.
    @discardableResult
    func addRemoteTmuxDisplayPane(
        remotePaneId: Int,
        title customTitle: String? = nil,
        focus: Bool = false,
        onInput: @escaping @Sendable (Data) -> Void,
        onResize: (@MainActor @Sendable (_ columns: Int, _ rows: Int) -> Void)? = nil
    ) -> TerminalPanel? {
        guard let paneId = bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first
        else { return nil }

        let title = customTitle ?? String(localized: "remoteTmux.tab.pane", defaultValue: "tmux pane")
        let surface = TerminalSurface(
            tabId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            manualIO: true,
            manualInputHandler: onInput
        )
        surface.onManualGridResize = onResize
        let newPanel = TerminalPanel(workspaceId: id, surface: surface)
        configureNewTerminalPanel(newPanel)
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = title

        guard let newTabId = bonsplitController.createTab(
            title: title,
            icon: "rectangle.connected.to.line.below",
            kind: SurfaceKind.terminal.rawValue,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            return nil
        }
        surfaceIdToPanelId[newTabId] = newPanel.id
        if focus {
            bonsplitController.focusPane(paneId)
        }
        bonsplitController.selectTab(newTabId)
        if focus {
            newPanel.focus()
        }
        // Reassert AppKit first-responder (keyboard focus) only on a user-initiated
        // attach; a background/socket mirror must not steal focus.
        applyTabSelection(tabId: newTabId, inPane: paneId, reassertAppKitFocus: focus)
        return newPanel
    }

    /// Closes one pane of a mirrored multi-pane tmux window (the pane-header ✕),
    /// confirming first when that pane is running an active foreground command —
    /// kill-pane is destructive, and the mirror pane has no local child process
    /// for the normal needs-confirm check. The decision uses a LIVE activity
    /// query (the subscription cache lags ~1s, which would let a just-started
    /// command slip through), falling back to the cached state when the link is
    /// down. The pane is removed by the resulting `%layout-change` (or
    /// `%window-close` for the window's last pane), never locally.
    ///
    /// Forwards to ``RemoteTmuxMirrorCoordinator`` (in `CmuxRemoteWorkspace`),
    /// which owns the orchestration; `Workspace` only supplies the modal
    /// confirmation through ``RemoteTmuxMirrorHosting``.
    func requestRemoteTmuxPaneClose(windowMirror: RemoteTmuxWindowMirror, tmuxPaneId: Int) {
        remoteTmuxMirrorCoordinator.requestRemoteTmuxPaneClose(
            windowMirror: windowMirror, tmuxPaneId: tmuxPaneId
        )
    }

    /// Updates a mirrored remote tmux tab's title (e.g. after a tmux
    /// `%window-renamed`). No-ops if the panel is no longer mounted.
    func updateRemoteTmuxTabTitle(panelId: UUID, title: String) {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        panelTitles[panelId] = title
        guard let existing = bonsplitController.tab(tabId), existing.title != title else { return }
        bonsplitController.updateTab(tabId, title: title, icon: nil, isDirty: nil)
    }

    /// Replace the terminal process behind an existing surface while preserving its pane and tab identity.
    @discardableResult
    func respawnTerminalSurface(
        panelId: UUID,
        command: String,
        workingDirectory: String? = nil,
        tmuxStartCommand: String? = nil,
        focus: Bool? = nil
    ) -> TerminalPanel? {
        guard let oldPanel = terminalPanel(for: panelId),
              let tabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId) else {
            return nil
        }

        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return nil }

        let inheritedConfig = inheritedTerminalConfig(preferredPanelId: panelId, inPane: paneId)
        let requestedWorkingDirectory = resolvedTerminalStartupWorkingDirectory(
            requestedWorkingDirectory: workingDirectory,
            sourcePanelId: panelId
        )
        let selectedInPane = bonsplitController.selectedTab(inPane: paneId)?.id == tabId
        let paneWasFocused = bonsplitController.focusedPaneId == paneId
        let shouldFocus = focus ?? (selectedInPane && paneWasFocused)
        let customTitle = panelCustomTitles[panelId]
        let customTitleSource = panelCustomTitleSources[panelId]
        let wasPinned = pinnedPanelIds.contains(panelId)
        let startCommand = tmuxStartCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacementTmuxStartCommand = (startCommand?.isEmpty == false) ? startCommand : trimmedCommand
        let focusPlacement = oldPanel.surface.focusPlacement
        let launchContext = oldPanel.surface.launchContext
        // Drop env this surface inherited from its (possibly previous) workspace,
        // then re-fold the current workspace's env below, so a terminal moved
        // between workspaces respawns with the destination's variables rather than
        // the source's (#5995). Only entries whose value still equals the seeded
        // workspace value are dropped, so an explicit per-surface override that
        // shares a workspace key keeps its value. configureNewTerminalPanel
        // re-records the seeded env for the replacement panel against the current
        // workspace.
        let oldSeededWorkspaceEnvironment = oldPanel.seededWorkspaceEnvironment
        let initialEnvironmentOverrides = oldPanel.surface.respawnInitialEnvironmentOverrides
            .filter { oldSeededWorkspaceEnvironment[$0.key] != $0.value }
        let additionalEnvironment = startupEnvironmentMergingWorkspaceEnvironment(
            oldPanel.surface.respawnAdditionalEnvironment.filter { oldSeededWorkspaceEnvironment[$0.key] != $0.value }
        )

        oldPanel.unfocus()
        oldPanel.hostedView.setVisibleInUI(false)
        TerminalWindowPortalRegistry.detach(hostedView: oldPanel.hostedView)
        oldPanel.surface.beginPortalCloseLifecycle(reason: "terminal.respawn")

        discardClosedPanelLifecycleState(
            panelId: panelId,
            tabId: tabId,
            paneId: paneId,
            panel: oldPanel,
            origin: "terminal_respawn",
            closePanel: false,
            publishSurfaceClosedEvent: false,
            clearSurfaceNotifications: false,
            requestTransferredRemoteCleanup: true,
            cleanupControllerSurfaceState: false
        )
        GhosttyApp.terminalSurfaceRegistry.unregister(oldPanel.surface)
        oldPanel.surface.teardownSurface()

        let replacementPanel = TerminalPanel(
            id: panelId,
            workspaceId: id,
            context: launchContext,
            configTemplate: inheritedConfig,
            workingDirectory: requestedWorkingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: trimmedCommand,
            tmuxStartCommand: replacementTmuxStartCommand,
            initialEnvironmentOverrides: initialEnvironmentOverrides,
            additionalEnvironment: additionalEnvironment,
            focusPlacement: focusPlacement
        )
        configureNewTerminalPanel(replacementPanel)
        panels[panelId] = replacementPanel
        panelTitles[panelId] = replacementPanel.displayTitle
        if let customTitle {
            panelCustomTitles[panelId] = customTitle
            panelCustomTitleSources[panelId] = customTitleSource ?? .user
        }
        if wasPinned {
            pinnedPanelIds.insert(panelId)
        }
        surfaceIdToPanelId[tabId] = panelId
        seedTerminalInheritanceFontPoints(panelId: panelId, configTemplate: inheritedConfig)

        let resolvedTitle = resolvedPanelTitle(panelId: panelId, fallback: replacementPanel.displayTitle)
        bonsplitController.updateTab(
            tabId,
            title: resolvedTitle,
            icon: .some(replacementPanel.displayIcon),
            iconImageData: .some(nil),
            kind: .some(SurfaceKind.terminal.rawValue),
            hasCustomTitle: customTitle != nil,
            isDirty: replacementPanel.isDirty,
            showsNotificationBadge: false,
            isLoading: false,
            isPinned: wasPinned
        )

        if shouldFocus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(tabId)
            focusPanel(panelId)
        } else if selectedInPane {
            bonsplitController.selectTab(tabId)
            applyTabSelection(tabId: tabId, inPane: paneId)
        } else {
            replacementPanel.unfocus()
        }

        owningTabManager?.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: id,
            panelId: panelId,
            reason: "terminalRespawn"
        )
        scheduleTerminalGeometryReconcile()
        scheduleFocusReconcile()
        return replacementPanel
    }

    /// Relaxed from `private` to `internal` so the lifted fork host conformance
    /// (`Workspace+AgentForkHosting.swift`) can reach it; the body is unchanged.
    func remoteTerminalStartupCommand() -> String? {
        guard !suppressRemoteTerminalStartupForSessionRestoreScaffold else {
            return nil
        }
        guard let command = remoteConfiguration?.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return nil
        }
        return command
    }

    /// Create a new browser panel split
    @discardableResult
    func newBrowserSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        url: URL? = nil,
        preferredProfileID: UUID? = nil,
        focus: Bool = true,
        creationPolicy: BrowserPanelCreationPolicy = .userInitiated,
        omnibarVisible: Bool = true,
        transparentBackground: Bool = false,
        bypassRemoteProxy: Bool = false,
        initialDividerPosition: CGFloat? = nil
    ) -> BrowserPanel? {
        // No local browser surfaces in a remote tmux mirror workspace (it is a
        // 1:1 view of a tmux session). See ``newBrowserSurface(inPane:)``.
        if isRemoteTmuxMirror { return nil }
        let browserEnabled = BrowserAvailabilitySettings.isEnabled()
        guard browserEnabled || creationPolicy.permitsCreationWhenBrowserDisabled else {
            if let url {
                _ = NSWorkspace.shared.open(url)
            }
            return nil
        }

        // Find the pane containing the source panel (the SurfaceLifecycleCoordinator
        // owns this resolution: surfaceId(forPanelId:) then the allPaneIds.first scan).
        guard let paneId = paneId(forPanelId: panelId) else { return nil }

        // Create browser panel
        let browserPanel = BrowserPanel(
            workspaceId: id,
            profileID: resolvedNewBrowserProfileID(
                preferredProfileID: preferredProfileID,
                sourcePanelId: panelId
            ),
            initialURL: url,
            renderInitialNavigation: browserEnabled || creationPolicy != .restoration,
            preloadInitialNavigationInBackground: creationPolicy.preloadsInitialNavigationInBackground,
            omnibarVisible: omnibarVisible,
            transparentBackground: transparentBackground,
            proxyEndpoint: remoteProxyEndpoint,
            bypassRemoteProxy: bypassRemoteProxy,
            isRemoteWorkspace: isRemoteWorkspace,
            remoteWebsiteDataStoreIdentifier: isRemoteWorkspace ? id : nil
        )
        configureBrowserPanel(browserPanel)
        panels[browserPanel.id] = browserPanel
        panelTitles[browserPanel.id] = browserPanel.displayTitle

        // Pre-generate the bonsplit tab ID so the mapping exists before the split lands.
        let newTab = Bonsplit.Tab(
            title: browserPanel.displayTitle,
            icon: browserPanel.displayIcon,
            kind: SurfaceKind.browser.rawValue,
            isDirty: browserPanel.isDirty,
            isLoading: browserPanel.isLoading,
            isAudioMuted: browserPanel.isMuted,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = browserPanel.id
        let previousFocusedPanelId = focusedPanelId

        // Create the split with the browser tab already present.
        // Mark this split as programmatic so didSplitPane doesn't auto-create a terminal.
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) else {
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            panels.removeValue(forKey: browserPanel.id)
            panelTitles.removeValue(forKey: browserPanel.id)
            return nil
        }
        applyInitialSplitDividerPosition(initialDividerPosition, sourcePaneId: paneId, newPaneId: newPaneId)
        setPreferredBrowserProfileID(browserPanel.profileID)
        publishCmuxSplitCreated(newPaneId, sourcePaneId: paneId, orientation: orientation, surfaceId: browserPanel.id, kind: "browser", origin: "browser_split", focused: focus)

        // See newTerminalSplit: suppress old view's becomeFirstResponder during reparenting.
        let previousHostedView = focusedTerminalPanel?.hostedView
        if focus {
            suppressReparentFocusUntilLayoutFollowUp(
                previousHostedView,
                reason: "workspace.browserSplitReparent"
            )
            focusPanel(browserPanel.id)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: browserPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installBrowserPanelSubscription(browserPanel)
        browserPanel.setRemoteWorkspaceStatus(browserRemoteWorkspaceStatusSnapshot())

        return browserPanel
    }

    /// Create a new browser surface in the specified pane.
    /// - Parameter focus: nil = focus only if the target pane is already focused (default UI behavior),
    ///                    true = force focus/selection of the new surface,
    ///                    false = never focus (used for internal placeholder repair paths).
    @discardableResult
    func newBrowserSurface(
        inPane paneId: PaneID,
        url: URL? = nil,
        initialRequest: URLRequest? = nil,
        focus: Bool? = nil,
        selectWhenNotFocused: Bool = false,
        insertAtEnd: Bool = false,
        preferredProfileID: UUID? = nil,
        bypassInsecureHTTPHostOnce: String? = nil,
        creationPolicy: BrowserPanelCreationPolicy = .userInitiated,
        omnibarVisible: Bool = true,
        transparentBackground: Bool = false,
        bypassRemoteProxy: Bool = false
    ) -> BrowserPanel? {
        // A remote tmux mirror workspace is a 1:1 view of a tmux session (which
        // has no browser concept). A local browser tab here would be an orphan
        // that the mirror's rebuild() never reconciles, breaking the 1:1
        // invariant — so refuse browser creation in a mirror workspace.
        if isRemoteTmuxMirror { return nil }
        let browserEnabled = BrowserAvailabilitySettings.isEnabled()
        guard browserEnabled || creationPolicy.permitsCreationWhenBrowserDisabled else {
            if let externalURL = url ?? initialRequest?.url {
                _ = NSWorkspace.shared.open(externalURL)
            }
            return nil
        }

        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let sourcePanelId = effectiveSelectedPanelId(inPane: paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let browserPanel = BrowserPanel(
            workspaceId: id,
            profileID: resolvedNewBrowserProfileID(
                preferredProfileID: preferredProfileID,
                sourcePanelId: sourcePanelId
            ),
            initialURL: url,
            initialRequest: initialRequest,
            renderInitialNavigation: browserEnabled || creationPolicy != .restoration,
            preloadInitialNavigationInBackground: creationPolicy.preloadsInitialNavigationInBackground,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce,
            omnibarVisible: omnibarVisible,
            transparentBackground: transparentBackground,
            proxyEndpoint: remoteProxyEndpoint,
            bypassRemoteProxy: bypassRemoteProxy,
            isRemoteWorkspace: isRemoteWorkspace,
            remoteWebsiteDataStoreIdentifier: isRemoteWorkspace ? id : nil
        )
        configureBrowserPanel(browserPanel)
        panels[browserPanel.id] = browserPanel
        panelTitles[browserPanel.id] = browserPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: browserPanel.displayTitle,
            icon: browserPanel.displayIcon,
            kind: SurfaceKind.browser.rawValue,
            isDirty: browserPanel.isDirty,
            isLoading: browserPanel.isLoading,
            isAudioMuted: browserPanel.isMuted,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: browserPanel.id)
            panelTitles.removeValue(forKey: browserPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = browserPanel.id
        setPreferredBrowserProfileID(browserPanel.profileID)

        // Keyboard/browser-open paths want "new tab at end" regardless of global new-tab placement.
        if insertAtEnd {
            let targetIndex = max(0, bonsplitController.tabs(inPane: paneId).count - 1)
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(browserPanel.id, paneId: paneId, kind: "browser", origin: "browser_tab", focused: shouldFocusNewTab)

        // Match terminal behavior: enforce deterministic selection + focus.
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            browserPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            if selectWhenNotFocused {
                hideBrowserPortalsForDeselectedTabs(inPane: paneId, selectedTabId: newTabId)
            }
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: browserPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installBrowserPanelSubscription(browserPanel)
        browserPanel.setRemoteWorkspaceStatus(browserRemoteWorkspaceStatusSnapshot())

        return browserPanel
    }

    /// Creates a sidebar extension browser tab in the requested pane and returns its panel.
    ///
    /// - Parameters:
    ///   - paneId: The pane that should receive the extension browser tab.
    ///   - title: The display title used for the tab and panel.
    ///   - focus: When true, selects the new tab and moves focus to its pane. The tab is not restored from saved workspace sessions.
    /// - Returns: The created extension browser panel, or `nil` if the pane cannot accept a new tab.
    /// Thin forwarder to ``SurfaceCreationCoordinator/newSidebarExtensionBrowserSurface(inPane:title:focus:host:)``.
    /// The coordinator owns the create-tab orchestration and drives every
    /// registry/bonsplit mutation back through this `Workspace`'s
    /// ``SurfaceCreationHosting`` conformance; it returns the new panel's `id`,
    /// which this maps back to the typed `CMUXSidebarExtensionBrowserPanel`.
    @discardableResult
    func newSidebarExtensionBrowserSurface(
        inPane paneId: PaneID,
        title: String,
        focus: Bool = true
    ) -> CMUXSidebarExtensionBrowserPanel? {
        surfaceCreation.newSidebarExtensionBrowserSurface(
            inPane: paneId,
            title: title,
            focus: focus,
            host: self
        ).flatMap { panels[$0] as? CMUXSidebarExtensionBrowserPanel }
    }

    /// Reuses an existing file-backed panel of kind `P` showing `filePath`, via
    /// the package-pure ``SurfaceReuseResolver``: candidates are built in
    /// `panels`-iteration order, keyed on symlink-resolved
    /// ``String/surfaceFilePathIdentity``, matching the legacy inline
    /// `for (existingId, panel) in panels { … resolvingSymlinksInPath … }` scans.
    /// Focuses the match when `focus` is set; returns `nil` to create anew.
    private func reusableFilePanel<P: Panel>(
        ofKind _: P.Type,
        filePath: String,
        focus: Bool,
        path: KeyPath<P, String>
    ) -> P? {
        let candidates = panels.compactMap { id, panel -> SurfaceReuseCandidate<String>? in
            guard let typed = panel as? P else { return nil }
            return SurfaceReuseCandidate(panelId: id, key: typed[keyPath: path].surfaceFilePathIdentity)
        }
        guard case let .focusExisting(existingId, shouldFocus) = surfaceReuseResolver.decision(
            candidates: candidates,
            requestedKey: filePath.surfaceFilePathIdentity,
            shouldFocusExisting: focus
        ) else { return nil }
        if shouldFocus { focusPanel(existingId) }
        return panels[existingId] as? P
    }

    /// Open the markdown viewer for `filePath`, reusing an existing
    /// `MarkdownPanel` in this workspace that already shows the same file.
    /// Paths are compared after symlink resolution so `./README.md` and a
    /// symlink pointing at the same file focus the same viewer.
    /// Returns `nil` when no existing viewer matches and split creation
    /// fails, so callers can fall back to the preferred editor / system opener.
    @discardableResult
    func openOrFocusMarkdownSplit(
        from panelId: UUID,
        filePath: String
    ) -> MarkdownPanel? {
        if let existing = reusableFilePanel(ofKind: MarkdownPanel.self, filePath: filePath, focus: true, path: \.filePath) {
            return existing
        }

        if let targetPane = preferredRightSideTargetPane(fromPanelId: panelId) {
            return newMarkdownSurface(inPane: targetPane, filePath: filePath, focus: true)
        }

        return newMarkdownSplit(
            from: panelId,
            orientation: .horizontal,
            insertFirst: false,
            filePath: filePath,
            focus: true
        )
    }

    /// Thin forwarder to ``SurfaceCreationCoordinator/newMarkdownSplit(fromPanelId:orientation:insertFirst:filePath:focus:fontSize:host:)``.
    /// The coordinator owns the split orchestration and drives every live read and
    /// registry/bonsplit mutation back through this `Workspace`'s
    /// ``SurfaceCreationHosting`` conformance; it returns the new panel's `id`,
    /// which this maps back to the typed `MarkdownPanel`.
    func newMarkdownSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        filePath: String,
        focus: Bool = true,
        fontSize: Double? = nil
    ) -> MarkdownPanel? {
        surfaceCreation.newMarkdownSplit(
            fromPanelId: panelId,
            orientation: orientation,
            insertFirst: insertFirst,
            filePath: filePath,
            focus: focus,
            fontSize: fontSize,
            host: self
        ).flatMap { panels[$0] as? MarkdownPanel }
    }

    /// Thin forwarder to ``SurfaceCreationCoordinator/newMarkdownSurface(inPane:filePath:focus:targetIndex:host:)``.
    /// The coordinator owns the create-tab orchestration and drives every live read
    /// and registry/bonsplit mutation back through this `Workspace`'s
    /// ``SurfaceCreationHosting`` conformance; it returns the new panel's `id`,
    /// which this maps back to the typed `MarkdownPanel`.
    @discardableResult
    func newMarkdownSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> MarkdownPanel? {
        surfaceCreation.newMarkdownSurface(
            inPane: paneId,
            filePath: filePath,
            focus: focus,
            targetIndex: targetIndex,
            host: self
        ).flatMap { panels[$0] as? MarkdownPanel }
    }

    /// Thin forwarder to ``SurfaceCreationCoordinator/newProjectSurface(inPane:projectPath:focus:targetIndex:host:)``.
    /// The coordinator owns the create-tab orchestration and drives every live
    /// read and registry/bonsplit mutation back through this `Workspace`'s
    /// ``SurfaceCreationHosting`` conformance; it returns the new panel's `id`,
    /// which this maps back to the typed `ProjectPanel`.
    @discardableResult
    func newProjectSurface(
        inPane paneId: PaneID,
        projectPath: String,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> ProjectPanel? {
        surfaceCreation.newProjectSurface(
            inPane: paneId,
            projectPath: projectPath,
            focus: focus,
            targetIndex: targetIndex,
            host: self
        ).flatMap { panels[$0] as? ProjectPanel }
    }

    @discardableResult
    func openOrFocusMarkdownSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool = true
    ) -> MarkdownPanel? {
        if let existing = reusableFilePanel(ofKind: MarkdownPanel.self, filePath: filePath, focus: focus, path: \.filePath) {
            return existing
        }

        return newMarkdownSurface(inPane: paneId, filePath: filePath, focus: focus)
    }

    /// Thin forwarder to ``SurfaceCreationCoordinator/splitPaneWithMarkdown(targetPane:orientation:insertFirst:filePath:host:)``.
    /// The coordinator owns the split orchestration and drives every live read and
    /// registry/bonsplit mutation back through this `Workspace`'s
    /// ``SurfaceCreationHosting`` conformance; it returns the new panel's `id`,
    /// which this maps back to the typed `MarkdownPanel`.
    @discardableResult
    func splitPaneWithMarkdown(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        filePath: String
    ) -> MarkdownPanel? {
        surfaceCreation.splitPaneWithMarkdown(
            targetPane: paneId,
            orientation: orientation,
            insertFirst: insertFirst,
            filePath: filePath,
            host: self
        ).flatMap { panels[$0] as? MarkdownPanel }
    }

    @discardableResult
    func openOrFocusFilePreviewSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool = true
    ) -> FilePreviewPanel? {
        if let existing = reusableFilePanel(ofKind: FilePreviewPanel.self, filePath: filePath, focus: focus, path: \.filePath) {
            return existing
        }

        return newFilePreviewSurface(inPane: paneId, filePath: filePath, focus: focus)
    }

    @discardableResult
    func openOrFocusFilePreviewSplit(
        from panelId: UUID,
        filePath: String
    ) -> FilePreviewPanel? {
        if let existing = reusableFilePanel(ofKind: FilePreviewPanel.self, filePath: filePath, focus: true, path: \.filePath) {
            return existing
        }

        if let targetPane = preferredRightSideTargetPane(fromPanelId: panelId) {
            return newFilePreviewSurface(inPane: targetPane, filePath: filePath, focus: true)
        }

        guard let sourcePaneId = paneId(forPanelId: panelId) else { return nil }
        return splitPaneWithFilePreview(
            targetPane: sourcePaneId,
            orientation: .horizontal,
            insertFirst: false,
            filePath: filePath
        )
    }

    /// Thin forwarder to ``SurfaceCreationCoordinator/newFilePreviewSurface(inPane:filePath:focus:targetIndex:host:)``.
    /// The coordinator owns the create-tab orchestration and drives every live read
    /// and registry/bonsplit mutation back through this `Workspace`'s
    /// ``SurfaceCreationHosting`` conformance; it returns the new panel's `id`,
    /// which this maps back to the typed `FilePreviewPanel`.
    @discardableResult
    func newFilePreviewSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> FilePreviewPanel? {
        surfaceCreation.newFilePreviewSurface(
            inPane: paneId,
            filePath: filePath,
            focus: focus,
            targetIndex: targetIndex,
            host: self
        ).flatMap { panels[$0] as? FilePreviewPanel }
    }

    @discardableResult
    func openOrFocusRightSidebarToolSurface(
        inPane paneId: PaneID,
        mode: RightSidebarMode,
        focus: Bool = true
    ) -> RightSidebarToolPanel? {
        guard mode.canOpenAsPane else { return nil }
        if let existing = reusableRightSidebarToolPanel(mode: mode, focus: focus) {
            return existing
        }
        return newRightSidebarToolSurface(inPane: paneId, mode: mode, focus: focus)
    }

    /// Reuses an existing `RightSidebarToolPanel` in this workspace whose `mode`
    /// matches, via the package-pure ``SurfaceReuseResolver``: candidates are
    /// built in `panels`-iteration order keyed on the mode raw value, matching
    /// the legacy inline `for (existingId, panel) in panels { … toolPanel.mode
    /// == mode … }` scan in ``openOrFocusRightSidebarToolSurface(inPane:mode:focus:)``.
    /// Focuses the match when `focus` is set; returns `nil` to create anew.
    private func reusableRightSidebarToolPanel(
        mode: RightSidebarMode,
        focus: Bool
    ) -> RightSidebarToolPanel? {
        let candidates = panels.compactMap { id, panel -> SurfaceReuseCandidate<String>? in
            guard let toolPanel = panel as? RightSidebarToolPanel else { return nil }
            return SurfaceReuseCandidate(panelId: id, key: toolPanel.mode.rawValue)
        }
        guard case let .focusExisting(existingId, shouldFocus) = surfaceReuseResolver.decision(
            candidates: candidates,
            requestedKey: mode.rawValue,
            shouldFocusExisting: focus
        ) else { return nil }
        if shouldFocus { focusPanel(existingId) }
        return panels[existingId] as? RightSidebarToolPanel
    }

    /// Thin forwarder to ``SurfaceCreationCoordinator/newRightSidebarToolSurface(inPane:modeRawValue:canOpenAsPane:focus:targetIndex:host:)``.
    /// The coordinator owns the create-tab orchestration and drives every registry/
    /// bonsplit mutation back through this `Workspace`'s ``SurfaceCreationHosting``
    /// conformance; it returns the new panel's `id`, which this maps back to the
    /// typed `RightSidebarToolPanel`. The mode crosses the seam as its frozen
    /// `rawValue` string, and `mode.canOpenAsPane` is resolved here (the affordance
    /// lives in a sibling UI package the workspace package does not depend on) and
    /// passed through, so the coordinator's leading guard is byte-identical.
    @discardableResult
    func newRightSidebarToolSurface(
        inPane paneId: PaneID,
        mode: RightSidebarMode,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> RightSidebarToolPanel? {
        surfaceCreation.newRightSidebarToolSurface(
            inPane: paneId,
            modeRawValue: mode.rawValue,
            canOpenAsPane: mode.canOpenAsPane,
            focus: focus,
            targetIndex: targetIndex,
            host: self
        ).flatMap { panels[$0] as? RightSidebarToolPanel }
    }

    /// Thin forwarder to ``SurfaceCreationCoordinator/newAgentSessionSurface(inPane:providerIDRawValue:rendererKindRawValue:workingDirectory:focus:targetIndex:host:)``.
    /// The coordinator owns the create-tab orchestration and drives every live read
    /// and registry/bonsplit mutation back through this `Workspace`'s
    /// ``SurfaceCreationHosting`` conformance; it returns the new panel's `id`,
    /// which this maps back to the typed `AgentSessionPanel`. The app enums cross the
    /// seam as their frozen `rawValue` strings.
    @discardableResult
    func newAgentSessionSurface(
        inPane paneId: PaneID,
        providerID: AgentSessionProviderID = .codex,
        rendererKind: AgentSessionRendererKind,
        workingDirectory: String? = nil,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> AgentSessionPanel? {
        surfaceCreation.newAgentSessionSurface(
            inPane: paneId,
            providerIDRawValue: providerID.rawValue,
            rendererKindRawValue: rendererKind.rawValue,
            workingDirectory: workingDirectory,
            focus: focus,
            targetIndex: targetIndex,
            host: self
        ).flatMap { panels[$0] as? AgentSessionPanel }
    }

    /// Thin forwarder to ``SurfaceCreationCoordinator/splitPaneWithFilePreview(targetPane:orientation:insertFirst:filePath:host:)``.
    /// The coordinator owns the split orchestration and drives every live read and
    /// registry/bonsplit mutation back through this `Workspace`'s
    /// ``SurfaceCreationHosting`` conformance; it returns the new panel's `id`,
    /// which this maps back to the typed `FilePreviewPanel`.
    @discardableResult
    func splitPaneWithFilePreview(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        filePath: String
    ) -> FilePreviewPanel? {
        surfaceCreation.splitPaneWithFilePreview(
            targetPane: paneId,
            orientation: orientation,
            insertFirst: insertFirst,
            filePath: filePath,
            host: self
        ).flatMap { panels[$0] as? FilePreviewPanel }
    }

    /// Tear down all panels in this workspace, freeing their Ghostty surfaces.
    /// Called before TabManager removes the workspace so child processes receive SIGHUP even if ARC deallocation is delayed.
    func teardownAllPanels() {
        surfaceTeardown.teardownAllPanels()
    }

    // MARK: SurfaceTeardownHosting witnesses touching private teardown state
    // Co-located with the `private` state/bodies they reach so they stay
    // `private` rather than widening for the cross-file conformance (the
    // ``SplitDetachHosting`` precedent). Remaining witnesses live in
    // `Workspace+SurfaceTeardownHosting.swift`.
    func disablePortalRendering() { layoutFollowUpCoordinator.disablePortalRendering() }
    func surfaceTeardownClearLayoutFollowUp() { layoutFollowUpCoordinator.clear() }
    func surfaceTeardownClearRemoteConfigurationIfWorkspaceBecameLocal() {
        clearRemoteConfigurationIfWorkspaceBecameLocal()
    }

    func discardAllPanelsForTeardown() {
        let panelEntries = Array(panels)
        for (panelId, panel) in panelEntries {
            discardClosedPanelLifecycleState(
                panelId: panelId,
                tabId: surfaceIdFromPanelId(panelId),
                paneId: paneId(forPanelId: panelId),
                panel: panel,
                origin: "workspace_teardown",
                closePanel: true,
                publishSurfaceClosedEvent: true,
                clearSurfaceNotifications: true,
                requestTransferredRemoteCleanup: true,
                cleanupControllerSurfaceState: true
            )
        }
    }

    func clearPerPanelTeardownBookkeeping() {
        restoredTerminalScrollbackByPanelId.removeAll(keepingCapacity: false)
#if DEBUG
        debugSessionSnapshotScrollbackFallbackPanelIds.removeAll(keepingCapacity: false)
        debugSessionSnapshotSyntheticScrollbackByPanelId.removeAll(keepingCapacity: false)
#endif
        pendingTerminalInput.clearRegistry()
        terminalInheritanceFontPointsByPanelId.removeAll(keepingCapacity: false)
        lastTerminalConfigInheritancePanelId = nil
        lastTerminalConfigInheritanceFontPoints = nil
    }

    /// Close a panel.
    /// Returns true when a bonsplit tab close request was issued.
    func closePanel(_ panelId: UUID, force: Bool = false) -> Bool {
        if let tabId = surfaceIdFromPanelId(panelId) {
            // Close the tab in bonsplit (this triggers delegate callback)
            return requestCloseTab(tabId, force: force)
        }

        // Mapping can transiently drift during split-tree mutations. If the target panel is
        // currently focused (or is the active terminal first responder), close whichever tab
        // bonsplit marks selected in that focused pane.
        let firstResponderPanelId = cmuxOwningGhosttyView(
            for: NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder
        )?.terminalSurface?.id
        let targetIsActive = focusedPanelId == panelId || firstResponderPanelId == panelId
        guard targetIsActive,
              let focusedPane = bonsplitController.focusedPaneId,
              let selected = bonsplitController.selectedTab(inPane: focusedPane) else {
#if DEBUG
            cmuxDebugLog(
                "surface.close.fallback.skip panel=\(panelId.uuidString.prefix(5)) " +
                "focusedPanel=\(focusedPanelId?.uuidString.prefix(5) ?? "nil") " +
                "firstResponderPanel=\(firstResponderPanelId?.uuidString.prefix(5) ?? "nil") " +
                "focusedPane=\(bonsplitController.focusedPaneId?.id.uuidString.prefix(5) ?? "nil")"
            )
#endif
            return false
        }

        let closed = requestCloseTab(selected.id, force: force)
#if DEBUG
        cmuxDebugLog(
            "surface.close.fallback panel=\(panelId.uuidString.prefix(5)) " +
            "selectedTab=\(String(describing: selected.id).prefix(5)) " +
            "closed=\(closed ? 1 : 0)"
        )
#endif
        return closed
    }

    func requestCloseTab(_ tabId: TabID, force: Bool) -> Bool {
        splitClose.requestCloseTab(tabId, force: force)
    }

    func paneId(forPanelId panelId: UUID) -> PaneID? {
        surfaceLifecycle.paneId(forPanelId: panelId)
    }

    private func applyInitialSplitDividerPosition(_ position: CGFloat?, sourcePaneId: PaneID, newPaneId: PaneID) {
        surfaceLifecycle.applyInitialSplitDividerPosition(position, sourcePaneId: sourcePaneId, newPaneId: newPaneId)
    }

    func indexInPane(forPanelId panelId: UUID) -> Int? {
        surfaceLifecycle.indexInPane(forPanelId: panelId)
    }

    /// Returns the nearest right-side sibling pane for browser/file-preview placement.
    /// The search is local to the source pane's ancestry in the split tree:
    /// use the closest horizontal ancestor where the source is in the first (left) branch.
    func preferredRightSideTargetPane(fromPanelId panelId: UUID) -> PaneID? {
        surfaceLifecycle.preferredRightSideTargetPane(fromPanelId: panelId)
    }

    /// Returns the top-right pane in the current split tree.
    /// When a workspace is already split, sidebar PR opens should reuse an existing pane
    /// instead of creating additional right splits.
    func topRightBrowserReusePane() -> PaneID? {
        surfaceLifecycle.topRightBrowserReusePane()
    }

    private func stageClosedBrowserRestoreSnapshotIfNeeded(for tab: Bonsplit.Tab, inPane pane: PaneID) {
        closedBrowserRestoreStaging.stageSnapshotIfNeeded(for: tab, inPane: pane)
    }

    private func clearStagedClosedBrowserRestoreSnapshot(for tabId: TabID) {
        closedBrowserRestoreStaging.clearSnapshot(forTabId: tabId)
    }

    @discardableResult
    func moveSurface(panelId: UUID, toPane paneId: PaneID, atIndex index: Int? = nil, focus: Bool = true) -> Bool {
        splitMoveReorder.moveSurface(panelId: panelId, toPane: paneId, atIndex: index, focus: focus)
    }

    @discardableResult
    private func moveSurfaceToAdjacentPane(panelId: UUID, direction: NavigationDirection) -> Bool {
        splitMoveReorder.moveSurfaceToAdjacentPane(panelId: panelId, direction: direction)
    }

    @discardableResult
    func reorderSurface(panelId: UUID, toIndex index: Int, focus: Bool = true) -> Bool {
        splitMoveReorder.reorderSurface(panelId: panelId, toIndex: index, focus: focus)
    }

    /// Reorders this workspace's remote-tmux mirror tabs so their left-to-right
    /// order matches `panelOrder` (the tmux window order), preserving the user's
    /// current tab selection and pane focus.
    ///
    /// This follows reorders that originate on the remote (a second tmux client, or
    /// a manual `move-window` / a `new-window` inserted mid-list). The cmux→tmux
    /// drag direction is handled by `handleMirrorWindowsReordered`. bonsplit's
    /// `reorderTab` selects+focuses the moved tab (and `selectTab`/`focusPane` fire
    /// the same activation), so the whole operation runs under
    /// ``isApplyingRemoteTmuxTabReorder`` to suppress that churn — a reactive tmux
    /// event must not steal focus or resume agents (socket focus policy). The user's
    /// selection/focus are unchanged, so bonsplit's internal state is just restored
    /// to match. No-ops when the tabs already match or aren't all in one pane.
    ///
    /// Known beta limitation: if a *remote* window reorder arrives while the user is
    /// mid tab-drag, this can move tabs under the drag. The trigger is narrow (a
    /// concurrent remote reorder during a ~1s local drag) and self-heals — the
    /// drop's `didReorderTabsInPane` reconciles `connection.windowOrder` to the
    /// final order. A drag-aware guard would need bonsplit to expose drag state.
    @discardableResult
    func reorderRemoteTmuxMirrorTabs(toPanelOrder panelOrder: [UUID]) -> Bool {
        splitMoveReorder.reorderRemoteTmuxMirrorTabs(toPanelOrder: panelOrder)
    }

    func detachSurface(panelId: UUID) -> DetachedSurfaceTransfer? {
        splitDetach.detachSurface(panelId: panelId)
    }

    // MARK: SplitDetachHosting witnesses touching private detach state
    //
    // Co-located with the `private` detach state they read/write
    // (`forceCloseTabIds`, `activeRemoteTerminalSurfaceIds`,
    // `skipControlMasterCleanupAfterDetachedRemoteTransfer`,
    // `detachSourceCapture`) so it stays `private` rather than widening to
    // `internal` for the cross-file conformance. The remaining
    // ``SplitDetachHosting`` witnesses live in `Workspace+SplitDetachHosting.swift`.

    func insertForceCloseTabId(_ tabId: TabID) {
        forceCloseTabIds.insert(tabId)
    }

    func removeForceCloseTabId(_ tabId: TabID) {
        forceCloseTabIds.remove(tabId)
    }

    func isActiveRemoteTerminalSurface(_ panelId: UUID) -> Bool {
        activeRemoteTerminalSurfaceIds.contains(panelId)
    }

    var activeRemoteTerminalSurfaceCount: Int {
        activeRemoteTerminalSurfaceIds.count
    }

    func markSkipControlMasterCleanupAfterDetachedRemoteTransfer() {
        skipControlMasterCleanupAfterDetachedRemoteTransfer = true
    }

    func captureDetachSource(panelId: UUID) -> Bool {
        guard let sourcePanel = panels[panelId] else { return false }
        detachSourceCapture = (panelId: panelId, panel: sourcePanel, paneId: paneId(forPanelId: panelId))
        return true
    }

    func publishCapturedDetachSource(transferCaptured: Bool) {
        guard let capture = detachSourceCapture else { return }
        detachSourceCapture = nil
        publishCmuxSurfaceClosed(
            capture.panelId,
            paneId: capture.paneId,
            panel: capture.panel,
            origin: transferCaptured ? "detach" : "detach_lost"
        )
    }

    func discardCapturedDetachSource() {
        detachSourceCapture = nil
    }

    @discardableResult
    func attachDetachedSurface(
        _ detached: DetachedSurfaceTransfer,
        inPane paneId: PaneID,
        atIndex index: Int? = nil,
        focus: Bool = true,
        focusIntent: PanelFocusIntent? = nil
    ) -> UUID? {
#if DEBUG
        let attachStart = ProcessInfo.processInfo.systemUptime
        cmuxDebugLog(
            "split.attach.begin ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
            "pane=\(paneId.id.uuidString.prefix(5)) index=\(index.map(String.init) ?? "nil") focus=\(focus ? 1 : 0)"
        )
#endif
        guard bonsplitController.allPaneIds.contains(paneId) else {
#if DEBUG
            cmuxDebugLog(
                "split.attach.fail ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
                "reason=invalidPane elapsedMs=\(debugElapsedMs(since: attachStart))"
            )
#endif
            return nil
        }
        guard panels[detached.panelId] == nil else {
#if DEBUG
            cmuxDebugLog(
                "split.attach.fail ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
                "reason=panelExists elapsedMs=\(debugElapsedMs(since: attachStart))"
            )
#endif
            return nil
        }

        if let directory = detached.directory {
            panelDirectories[detached.panelId] = directory
        }
        if let ttyName = detached.ttyName?.trimmingCharacters(in: .whitespacesAndNewlines), !ttyName.isEmpty {
            surfaceTTYNames[detached.panelId] = ttyName
        } else {
            surfaceTTYNames.removeValue(forKey: detached.panelId)
        }
        syncRemotePortScanTTYs()
        if let cachedTitle = detached.cachedTitle {
            panelTitles[detached.panelId] = cachedTitle
        }
        if let customTitle = detached.customTitle {
            panelCustomTitles[detached.panelId] = customTitle
            panelCustomTitleSources[detached.panelId] = detached.customTitleSource ?? .user
        }
        if detached.isPinned {
            pinnedPanelIds.insert(detached.panelId)
        } else {
            pinnedPanelIds.remove(detached.panelId)
        }
        if detached.manuallyUnread {
            manualUnreadPanelIds.insert(detached.panelId)
            manualUnreadMarkedAt[detached.panelId] = .distantPast
        } else {
            manualUnreadPanelIds.remove(detached.panelId)
            manualUnreadMarkedAt.removeValue(forKey: detached.panelId)
        }
        if let restoredUnreadIndicator = detached.restoredUnreadIndicator {
            restoredUnreadPanelIndicators[detached.panelId] = restoredUnreadIndicator
        } else {
            restoredUnreadPanelIndicators.removeValue(forKey: detached.panelId)
        }
        let detachedBrowserMuted = (detached.panel as? BrowserPanel)?.isMuted ?? false

        guard let newTabId = bonsplitController.createTab(
            title: detached.title,
            hasCustomTitle: detached.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            icon: detached.icon,
            iconImageData: detached.iconImageData,
            kind: detached.kind,
            isDirty: detached.panel.isDirty,
            isLoading: detached.isLoading,
            isAudioMuted: detachedBrowserMuted,
            isPinned: detached.isPinned,
            inPane: paneId
        ) else {
            removeBrowserOpenTabSuggestionIfNeeded(panel: detached.panel, panelId: detached.panelId)
            panels.removeValue(forKey: detached.panelId)
            panelDirectories.removeValue(forKey: detached.panelId)
            surfaceTTYNames.removeValue(forKey: detached.panelId)
            surfaceResumeBindingsByPanelId.removeValue(forKey: detached.panelId)
            syncRemotePortScanTTYs()
            panelTitles.removeValue(forKey: detached.panelId)
            panelCustomTitles.removeValue(forKey: detached.panelId)
            panelCustomTitleSources.removeValue(forKey: detached.panelId)
            pinnedPanelIds.remove(detached.panelId)
            manualUnreadPanelIds.remove(detached.panelId)
            restoredUnreadPanelIndicators.removeValue(forKey: detached.panelId)
            manualUnreadMarkedAt.removeValue(forKey: detached.panelId)
            panelSubscriptions.removeValue(forKey: detached.panelId)
            if let agentPanel = detached.panel as? AgentSessionPanel {
                agentPanel.onDisplayStateChanged = nil
                agentSessionPanelCallbackIds.remove(detached.panelId)
            }
#if DEBUG
            cmuxDebugLog(
                "split.attach.fail ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
                "reason=createTabFailed elapsedMs=\(debugElapsedMs(since: attachStart))"
            )
#endif
            return nil
        }

        surfaceIdToPanelId[newTabId] = detached.panelId
        panels[detached.panelId] = detached.panel
        if let terminalPanel = detached.panel as? TerminalPanel {
            terminalPanel.updateWorkspaceId(id)
            configureTerminalPanel(terminalPanel)
        } else if let browserPanel = detached.panel as? BrowserPanel {
            browserPanel.reattachToWorkspace(
                id,
                isRemoteWorkspace: isRemoteWorkspace,
                remoteWebsiteDataStoreIdentifier: isRemoteWorkspace ? id : nil,
                proxyEndpoint: remoteProxyEndpoint,
                remoteStatus: browserRemoteWorkspaceStatusSnapshot()
            )
            configureBrowserPanel(browserPanel)
            installBrowserPanelSubscription(browserPanel)
        } else if let rightSidebarToolPanel = detached.panel as? RightSidebarToolPanel {
            rightSidebarToolPanel.reattach(to: self)
        }
        hostEnvironment?.notificationStore?.rebindSurfaceNotifications(
            fromTabId: detached.sourceWorkspaceId,
            toTabId: id,
            surfaceId: detached.panelId
        )
        if let restorableAgent = detached.restorableAgent {
            restoredAgentSnapshotsByPanelId[detached.panelId] = restorableAgent
            invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: detached.panelId)
            if let resumeState = detached.restorableAgentResumeState {
                restoredAgentResumeStatesByPanelId[detached.panelId] = resumeState
            } else {
                restoredAgentResumeStatesByPanelId.removeValue(forKey: detached.panelId)
            }
        } else {
            restoredAgentResumeStatesByPanelId.removeValue(forKey: detached.panelId)
        }
        if let resumeBinding = detached.resumeBinding, !resumeBinding.isProcessDetected {
            surfaceResumeBindingsByPanelId[detached.panelId] = resumeBinding
        } else {
            surfaceResumeBindingsByPanelId.removeValue(forKey: detached.panelId)
        }
        adoptDetachedAgentRuntimeState(detached.agentRuntime)
        if let markdownPanel = detached.panel as? MarkdownPanel,
           panelSubscriptions[markdownPanel.id] == nil {
            installMarkdownPanelSubscription(markdownPanel)
        }
        if let filePreviewPanel = detached.panel as? FilePreviewPanel,
           panelSubscriptions[filePreviewPanel.id] == nil {
            installFilePreviewPanelSubscription(filePreviewPanel)
        }
        if let agentPanel = detached.panel as? AgentSessionPanel {
            agentPanel.updateWorkspaceId(id)
            if !agentSessionPanelCallbackIds.contains(agentPanel.id) {
                installAgentSessionPanelSubscription(agentPanel)
            }
        }
        let didAdoptWorkspaceRemoteTracking = shouldAdoptDetachedWorkspaceRemoteTracking(detached)
        if didAdoptWorkspaceRemoteTracking,
           let remotePTYSessionID = normalizedRemotePTYSessionID(detached.remotePTYSessionID) {
            remoteRelaySession.setRemotePTYSessionID(remotePTYSessionID, forPanel: detached.panelId)
        } else {
            remoteRelaySession.removeRemotePTYSessionID(forPanel: detached.panelId)
        }
        if didAdoptWorkspaceRemoteTracking {
            registerRemoteRelayIDAliases(
                snapshotWorkspaceId: detached.sourceWorkspaceId,
                snapshotPanelId: detached.panelId,
                restoredPanelId: detached.panelId
            )
            trackRemoteTerminalSurface(detached.panelId)
        }
        if let cleanupConfiguration = detached.remoteCleanupConfiguration {
            if didAdoptWorkspaceRemoteTracking {
                transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: detached.panelId)
            } else {
                transferredRemoteCleanupConfigurationsByPanelId[detached.panelId] = cleanupConfiguration
            }
        } else {
            transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: detached.panelId)
        }
        if let index {
            _ = bonsplitController.reorderTab(newTabId, toIndex: index)
        }
        syncPinnedStateForTab(newTabId, panelId: detached.panelId)
        syncUnreadBadgeStateForPanel(detached.panelId)
        normalizePinnedTabs(in: paneId)
        publishCmuxSurfaceCreated(detached.panelId, paneId: paneId, kind: Self.cmuxEventSurfaceKind(detached.panel), origin: "detach_attach", focused: focus)

        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId, focusIntent: focusIntent)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()

#if DEBUG
        cmuxDebugLog(
            "split.attach.end ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
            "tab=\(newTabId.uuid.uuidString.prefix(5)) pane=\(paneId.id.uuidString.prefix(5)) " +
            "index=\(index.map(String.init) ?? "nil") focus=\(focus ? 1 : 0) " +
            "elapsedMs=\(debugElapsedMs(since: attachStart))"
        )
#endif
        return detached.panelId
    }

    private func shouldAdoptDetachedWorkspaceRemoteTracking(_ detached: DetachedSurfaceTransfer) -> Bool {
        guard detached.isRemoteTerminal else { return false }
        if detached.sourceWorkspaceId == id { return true }
        guard let detachedRelayPort = detached.remoteRelayPort,
              detachedRelayPort > 0,
              let currentRelayPort = remoteConfiguration?.relayPort,
              currentRelayPort > 0 else {
            return false
        }
        return detachedRelayPort == currentRelayPort
    }
    // MARK: - Focus Management

    private func preserveFocusAfterNonFocusSplit(
        preferredPanelId: UUID?,
        splitPanelId: UUID,
        previousHostedView: GhosttySurfaceScrollView?
    ) {
        guard let preferredPanelId, panels[preferredPanelId] != nil else {
            clearNonFocusSplitFocusReassert()
            scheduleFocusReconcile()
            return
        }

        let generation = beginNonFocusSplitFocusReassert(
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        )

        // Bonsplit splitPane focuses the newly created pane and may emit one delayed
        // didSelect/didFocus callback. Re-assert focus over multiple turns so model
        // focus and AppKit first responder stay aligned with non-focus-intent splits.
        reassertFocusAfterNonFocusSplit(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId,
            previousHostedView: previousHostedView,
            allowPreviousHostedView: true
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reassertFocusAfterNonFocusSplit(
                generation: generation,
                preferredPanelId: preferredPanelId,
                splitPanelId: splitPanelId,
                previousHostedView: previousHostedView,
                allowPreviousHostedView: false
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reassertFocusAfterNonFocusSplit(
                    generation: generation,
                    preferredPanelId: preferredPanelId,
                    splitPanelId: splitPanelId,
                    previousHostedView: previousHostedView,
                    allowPreviousHostedView: false
                )
                self.scheduleFocusReconcile()
                self.clearNonFocusSplitFocusReassert(generation: generation)
            }
        }
    }

    private func reassertFocusAfterNonFocusSplit(
        generation: UInt64,
        preferredPanelId: UUID,
        splitPanelId: UUID,
        previousHostedView: GhosttySurfaceScrollView?,
        allowPreviousHostedView: Bool
    ) {
        guard matchesPendingNonFocusSplitFocusReassert(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        ) else {
            return
        }

        guard panels[preferredPanelId] != nil else {
            clearNonFocusSplitFocusReassert(generation: generation)
            return
        }

        if focusedPanelId == splitPanelId {
            focusPanel(
                preferredPanelId,
                previousHostedView: allowPreviousHostedView ? previousHostedView : nil
            )
            return
        }

        guard focusedPanelId == preferredPanelId,
              let terminalPanel = terminalPanel(for: preferredPanelId) else {
            return
        }
        terminalPanel.hostedView.ensureFocus(for: id, surfaceId: preferredPanelId)
    }

    func focusPanel(
        _ panelId: UUID,
        previousHostedView: GhosttySurfaceScrollView? = nil,
        trigger: FocusPanelTrigger = .standard,
        focusIntent: PanelFocusIntent? = nil
    ) {
        markExplicitFocusIntent(on: panelId)
#if DEBUG
        let pane = bonsplitController.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let triggerLabel = trigger == .terminalFirstResponder ? "firstResponder" : "standard"
        cmuxDebugLog("focus.panel panel=\(panelId.uuidString.prefix(5)) pane=\(pane) trigger=\(triggerLabel)")
        hostEnvironment?.focusLog.append(
            "Workspace.focusPanel panelId=\(panelId.uuidString) focusedPane=\(pane) trigger=\(triggerLabel)"
        )
#endif
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        // In canvas mode, focusing a panel also brings it forward as its
        // pane's selected tab so focus and visibility never diverge.
        if layoutMode == .canvas {
            canvasModel.selectPanel(panelId)
        }
        let currentlyFocusedPanelId = focusedPanelId

        // Capture the currently focused terminal view so we can explicitly move AppKit first
        // responder when focusing another terminal (helps avoid "highlighted but typing goes to
        // another pane" after heavy split/tab mutations).
        // When a caller passes an explicit previousHostedView (e.g. during split creation where
        // bonsplit has already mutated focusedPaneId), prefer it over the derived value.
        let previousTerminalHostedView = previousHostedView ?? focusedTerminalPanel?.hostedView

        // `selectTab` does not necessarily move bonsplit's focused pane. For programmatic focus
        // (socket API, notification click, etc.), ensure the target tab's pane becomes focused
        // so `focusedPanelId` and follow-on focus logic are coherent.
        let targetPaneId = bonsplitController.allPaneIds.first(where: { paneId in
            bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId })
        })
        let selectionAlreadyConverged: Bool = {
            guard let targetPaneId else { return false }
            return bonsplitController.focusedPaneId == targetPaneId &&
                bonsplitController.selectedTab(inPane: targetPaneId)?.id == tabId
        }()
        let targetHostedView = terminalPanel(for: panelId)?.hostedView
        let targetHasPendingReparentSuppression = targetHostedView.map { hostedView in
            hostedView.isSuppressingReparentFocusForLayoutFollowUp() ||
                layoutFollowUpCoordinator.hasPendingReparentFocusSuppression(for: hostedView)
        } ?? false
        let shouldSuppressReentrantRefocus =
            trigger == .terminalFirstResponder &&
            selectionAlreadyConverged &&
            targetHasPendingReparentSuppression
#if DEBUG
        let targetPaneShort = targetPaneId.map { String($0.id.uuidString.prefix(5)) } ?? "nil"
        let focusedPaneShort = bonsplitController.focusedPaneId.map { String($0.id.uuidString.prefix(5)) } ?? "nil"
        let selectedTabShort = bonsplitController.focusedPaneId
            .flatMap { bonsplitController.selectedTab(inPane: $0)?.id }
            .map { String($0.uuid.uuidString.prefix(5)) } ?? "nil"
        let currentPanelShort = currentlyFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        cmuxDebugLog(
            "focus.panel.begin workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) trigger=\(String(describing: trigger)) " +
            "targetPane=\(targetPaneShort) focusedPane=\(focusedPaneShort) selectedTab=\(selectedTabShort) " +
            "converged=\(selectionAlreadyConverged ? 1 : 0) " +
            "currentPanel=\(currentPanelShort)"
        )
#endif
        if shouldSuppressReentrantRefocus, currentlyFocusedPanelId == panelId {
            if let targetPaneId, let panel = panels[panelId] {
                let activationIntent = focusIntent ?? panel.preferredFocusIntentForActivation()
                applyTabSelection(
                    tabId: tabId,
                    inPane: targetPaneId,
                    reassertAppKitFocus: false,
                    focusIntent: activationIntent,
                    previousTerminalHostedView: previousTerminalHostedView
                )
            }
            beginEventDrivenLayoutFollowUp(
                reason: "workspace.focusPanel.terminal",
                terminalFocusPanelId: panelId
            )
            return
        }

        if let targetPaneId, !selectionAlreadyConverged {
#if DEBUG
            cmuxDebugLog(
                "focus.panel.focusPane workspace=\(id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) pane=\(targetPaneId.id.uuidString.prefix(5))"
            )
#endif
            bonsplitController.focusPane(targetPaneId)
        }

        if !selectionAlreadyConverged {
#if DEBUG
            cmuxDebugLog(
                "focus.panel.selectTab workspace=\(id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) tab=\(tabId.uuid.uuidString.prefix(5))"
            )
#endif
            bonsplitController.selectTab(tabId)
        }

        if let targetPaneId {
            let activationIntent = focusIntent ?? panels[panelId]?.preferredFocusIntentForActivation()
            applyTabSelection(
                tabId: tabId,
                inPane: targetPaneId,
                reassertAppKitFocus: !shouldSuppressReentrantRefocus,
                focusIntent: activationIntent,
                resumeHibernatedAgent: true,
                previousTerminalHostedView: previousTerminalHostedView
            )
        }
        if currentlyFocusedPanelId != panelId {
            syncUnreadBadgeStateForAllPanels()
        }

        if let browserPanel = panels[panelId] as? BrowserPanel {
            maybeAutoFocusBrowserAddressBarOnPanelFocus(browserPanel, trigger: trigger)
        }

        if trigger == .terminalFirstResponder,
           panels[panelId] is TerminalPanel {
            beginEventDrivenLayoutFollowUp(
                reason: "workspace.focusPanel.terminal",
                terminalFocusPanelId: panelId
            )
        }
    }

    private func maybeAutoFocusBrowserAddressBarOnPanelFocus(
        _ browserPanel: BrowserPanel,
        trigger: FocusPanelTrigger
    ) {
        guard trigger == .standard else { return }
        guard !isCommandPaletteVisibleForWorkspaceWindow() else { return }
        guard !browserPanel.shouldSuppressOmnibarAutofocus() else { return }
        guard browserPanel.isShowingNewTabPage || browserPanel.preferredURLStringForOmnibar() == nil else { return }

        _ = browserPanel.requestAddressBarFocus()
        NotificationCenter.default.post(name: .browserFocusAddressBar, object: browserPanel.id)
    }

    private func isCommandPaletteVisibleForWorkspaceWindow() -> Bool {
        guard let app = hostEnvironment else {
            return false
        }

        if let manager = app.tabManagerFor(tabId: id),
           let windowId = app.windowId(for: manager),
           let window = app.mainWindow(for: windowId),
           app.isCommandPaletteVisible(for: window) {
            return true
        }

        if let keyWindow = NSApp.keyWindow, app.isCommandPaletteVisible(for: keyWindow) {
            return true
        }
        if let mainWindow = NSApp.mainWindow, app.isCommandPaletteVisible(for: mainWindow) {
            return true
        }
        return false
    }

    func moveFocus(direction: NavigationDirection) {
        if layoutMode == .canvas {
            moveCanvasFocus(direction: direction)
            return
        }
        let previousFocusedPanelId = focusedPanelId

        // Unfocus the currently-focused panel before navigating.
        if let prevPanelId = previousFocusedPanelId, let prev = panels[prevPanelId] {
            prev.unfocus()
        }

        bonsplitController.navigateFocus(direction: direction)

        // Always reconcile selection/focus after navigation so AppKit first-responder and
        // bonsplit's focused pane stay aligned, even through split tree mutations.
        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }

    }

    // MARK: - Surface Navigation

    /// Select the next surface in the currently focused pane
    func selectNextSurface() {
        if layoutMode == .canvas, selectAdjacentCanvasTab(offset: 1) { return }
        bonsplitController.selectNextTab()

        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    /// Select the previous surface in the currently focused pane
    func selectPreviousSurface() {
        if layoutMode == .canvas, selectAdjacentCanvasTab(offset: -1) { return }
        bonsplitController.selectPreviousTab()

        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    /// Select a surface by index in the currently focused pane
    func selectSurface(at index: Int) {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard index >= 0 && index < tabs.count else { return }
        bonsplitController.selectTab(tabs[index].id)

        if let tabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }

    /// Select the last surface in the currently focused pane
    func selectLastSurface() {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard let last = tabs.last else { return }
        bonsplitController.selectTab(last.id)

        if let tabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }

    /// Create a new terminal surface in the currently focused pane
    @discardableResult
    func newTerminalSurfaceInFocusedPane(focus: Bool? = nil, initialInput: String? = nil) -> TerminalPanel? {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return nil }
        // In canvas mode, Cmd+T means "new tab in the focused canvas pane":
        // remember the anchor panel so the new one joins its pane instead of
        // floating as a separate canvas pane.
        let canvasAnchorPanelId = layoutMode == .canvas ? focusedPanelId : nil
        let panel = newTerminalSurface(
            inPane: focusedPaneId,
            focus: focus,
            initialInput: initialInput,
            inheritWorkingDirectoryFallback: true
        )
        if let panel, let anchor = canvasAnchorPanelId {
            joinNewPanelIntoCanvasPane(panel.id, anchor: anchor)
        }
        return panel
    }

    @discardableResult
    func clearSplitZoom() -> Bool {
        bonsplitController.clearPaneZoom()
    }

    @discardableResult
    func toggleSplitZoom(panelId: UUID) -> Bool {
        let wasSplitZoomed = bonsplitController.isSplitZoomed
        guard let paneId = paneId(forPanelId: panelId) else { return false }
        guard bonsplitController.togglePaneZoom(inPane: paneId) else { return false }
        focusPanel(panelId)
        reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
        reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason: "workspace.toggleSplitZoom")
        if let browserPanel = browserPanel(for: panelId) {
            browserPanel.preparePortalHostReplacementForNextDistinctClaim(
                inPane: paneId,
                reason: "workspace.toggleSplitZoom"
            )
        }
        beginEventDrivenLayoutFollowUp(
            reason: "workspace.toggleSplitZoom",
            browserPanelId: browserPanel(for: panelId) != nil ? panelId : nil,
            browserExitFocusPanelId: (wasSplitZoomed && !bonsplitController.isSplitZoomed) ? panelId : nil,
            includeGeometry: true
        )
        return true
    }

    // MARK: - Flash/Notification Support

    func triggerFocusFlash(panelId: UUID) {
        requestAttentionFlash(panelId: panelId, reason: .navigation)
    }

    func triggerNotificationFocusFlash(
        panelId: UUID,
        requiresSplit: Bool = false,
        shouldFocus: Bool = true
    ) {
        guard terminalPanel(for: panelId) != nil else { return }
        if shouldFocus {
            focusPanel(panelId)
        }
        let isSplit = bonsplitController.allPaneIds.count > 1 || panels.count > 1
        if requiresSplit && !isSplit {
            return
        }
        requestAttentionFlash(panelId: panelId, reason: .notificationArrival)
    }

    func triggerNotificationDismissFlash(panelId: UUID) {
        guard terminalPanel(for: panelId) != nil else { return }
        requestAttentionFlash(panelId: panelId, reason: .notificationDismiss)
    }

    func triggerUnreadIndicatorDismissFlash(panelId: UUID) {
        guard terminalPanel(for: panelId) != nil else { return }
        requestAttentionFlash(panelId: panelId, reason: .unreadIndicatorDismiss)
    }

    func triggerDebugFlash(panelId: UUID) {
        guard panels[panelId] != nil else { return }
        focusPanel(panelId)
        requestAttentionFlash(panelId: panelId, reason: .debug)
    }

    // MARK: - Portal Lifecycle

    /// Hide all terminal portal views for this workspace.
    /// Called before the workspace is unmounted to prevent portal-hosted terminal
    /// views from covering browser panes in the newly selected workspace.
    func hideAllTerminalPortalViews() {
        for panel in panels.values {
            guard let terminal = panel as? TerminalPanel else { continue }
            terminal.hostedView.setVisibleInUI(false)
            TerminalWindowPortalRegistry.hideHostedView(terminal.hostedView)
        }
    }

    func hideAllBrowserPortalViews() {
        for panel in panels.values {
            guard let browser = panel as? BrowserPanel else { continue }
            browser.hideBrowserPortalView(source: "workspaceRetire")
        }
    }

    /// Enables/disables portal rendering for this workspace. Forwards to
    /// ``WorkspaceLayoutFollowUpCoordinator/setPortalRenderingEnabled(_:reason:)``;
    /// the coordinator owns the `portalRenderingEnabled` flag and drives the
    /// hide-all teardown through ``WorkspaceLayoutFollowUpHosting``.
    func setPortalRenderingEnabled(_ enabled: Bool, reason: String) {
        layoutFollowUpCoordinator.setPortalRenderingEnabled(enabled, reason: reason)
    }

    func setAgentHibernationAutoResumePresentationVisible(_ isVisible: Bool) {
        guard agentHibernationAutoResumePresentationVisible != isVisible else { return }
        agentHibernationAutoResumePresentationVisible = isVisible
        guard isVisible else { return }
        reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
    }

    /// Create a new terminal panel (used when replacing the last panel)
    @discardableResult
    func createReplacementTerminalPanel() -> TerminalPanel {
        var replacementConfig = inheritedTerminalConfig(
            preferredPanelId: focusedPanelId,
            inPane: bonsplitController.focusedPaneId
        )
        let pendingRemoteDisconnect = pendingRemoteDisconnectReplacement
        pendingRemoteDisconnectReplacement = nil
        let replacementInitialCommand: String? = pendingRemoteDisconnect.map {
            RemoteDisconnectPlaceholderScript(
                target: $0.target,
                reconnectCommand: $0.reconnectCommand,
                strings: .appLocalized
            ).materialize()
        }
        if replacementInitialCommand != nil {
            var config = replacementConfig ?? CmuxSurfaceConfigTemplate()
            config.waitAfterCommand = true
            replacementConfig = config
        }
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: replacementConfig,
            portOrdinal: portOrdinal,
            initialCommand: replacementInitialCommand,
            additionalEnvironment: startupEnvironmentMergingWorkspaceEnvironment([:])
        )
        configureNewTerminalPanel(newPanel)
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        if replacementInitialCommand != nil {
            remoteDisconnectPlaceholderPanelIds.insert(newPanel.id)
        }
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: replacementConfig)

        // Create tab in bonsplit
        if let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal.rawValue,
            isDirty: newPanel.isDirty,
            isPinned: false
        ) {
            surfaceIdToPanelId[newTabId] = newPanel.id
        }

        return newPanel
    }

    /// Check if any panel needs close confirmation
    func needsConfirmClose() -> Bool {
        for (panelId, _) in panels {
            if panelNeedsConfirmClose(panelId: panelId) {
                return true
            }
        }
        return false
    }

    private func reconcileFocusState() {
        guard layoutFollowUpCoordinator.portalRenderingEnabled else { return }
        guard !isReconcilingFocusState else { return }
        isReconcilingFocusState = true
        defer { isReconcilingFocusState = false }

        // Source of truth: bonsplit focused pane + selected tab.
        // AppKit first responder must converge to this model state, not the other way around.
        var targetPanelId: UUID?

        if let focusedPane = bonsplitController.focusedPaneId,
           let focusedTab = bonsplitController.selectedTab(inPane: focusedPane),
           let mappedPanelId = panelIdFromSurfaceId(focusedTab.id),
           panels[mappedPanelId] != nil {
            targetPanelId = mappedPanelId
        } else {
            for pane in bonsplitController.allPaneIds {
                guard let selectedTab = bonsplitController.selectedTab(inPane: pane),
                      let mappedPanelId = panelIdFromSurfaceId(selectedTab.id),
                      panels[mappedPanelId] != nil else { continue }
                bonsplitController.focusPane(pane)
                bonsplitController.selectTab(selectedTab.id)
                targetPanelId = mappedPanelId
                break
            }
        }

        if targetPanelId == nil, let fallbackPanelId = panels.keys.first {
            targetPanelId = fallbackPanelId
            if let fallbackTabId = surfaceIdFromPanelId(fallbackPanelId),
               let fallbackPane = bonsplitController.allPaneIds.first(where: { paneId in
                   bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == fallbackTabId })
               }) {
                bonsplitController.focusPane(fallbackPane)
                bonsplitController.selectTab(fallbackTabId)
            }
        }

        guard let targetPanelId, let targetPanel = panels[targetPanelId] else { return }

        for (panelId, panel) in panels where panelId != targetPanelId {
            panel.unfocus()
        }

        targetPanel.focus()
        if let terminalPanel = targetPanel as? TerminalPanel {
            terminalPanel.hostedView.ensureFocus(for: id, surfaceId: targetPanelId)
        }
        if let dir = panelDirectories[targetPanelId] {
            currentDirectory = dir
        }
        gitBranch = panelGitBranches[targetPanelId]
        pullRequest = panelPullRequests[targetPanelId]
    }

    /// Reconcile focus/first-responder convergence.
    /// Coalesce to the next main-queue turn so bonsplit selection/pane mutations settle first.
    func scheduleFocusReconcile() {
        guard layoutFollowUpCoordinator.portalRenderingEnabled else { return }
#if DEBUG
        if isDetachingCloseTransaction {
            debugFocusReconcileScheduledDuringDetachCount += 1
        }
#endif
        guard !focusReconcileScheduled else { return }
        focusReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.layoutFollowUpCoordinator.portalRenderingEnabled else {
                self.focusReconcileScheduled = false
                return
            }
            self.focusReconcileScheduled = false
            self.reconcileFocusState()
        }
    }

    /// Begins (or refreshes) an event-driven layout follow-up. Forwards to
    /// ``WorkspaceLayoutFollowUpCoordinator/begin(reason:browserPanelId:browserExitFocusPanelId:terminalFocusPanelId:includeGeometry:)``,
    /// which owns the follow-up state machine.
    private func beginEventDrivenLayoutFollowUp(
        reason: String,
        browserPanelId: UUID? = nil,
        browserExitFocusPanelId: UUID? = nil,
        terminalFocusPanelId: UUID? = nil,
        includeGeometry: Bool = false
    ) {
        layoutFollowUpCoordinator.begin(
            reason: reason,
            browserPanelId: browserPanelId,
            browserExitFocusPanelId: browserExitFocusPanelId,
            terminalFocusPanelId: terminalFocusPanelId,
            includeGeometry: includeGeometry
        )
    }

    /// Suppresses a terminal view's reparent-focus side effects until the layout
    /// follow-up settles. Forwards to
    /// ``WorkspaceLayoutFollowUpCoordinator/suppressReparentFocus(_:reason:)``.
    private func suppressReparentFocusUntilLayoutFollowUp(
        _ hostedView: GhosttySurfaceScrollView?,
        reason: String
    ) {
        layoutFollowUpCoordinator.suppressReparentFocus(hostedView, reason: reason)
    }

#if DEBUG
    func debugBeginReparentFocusSuppressionForTesting(_ hostedView: GhosttySurfaceScrollView, reason: String) {
        layoutFollowUpCoordinator.suppressReparentFocus(hostedView, reason: reason)
    }

    func debugAttemptEventDrivenLayoutFollowUpForTesting() {
        layoutFollowUpCoordinator.attempt()
    }

    func debugHasPendingReparentFocusSuppressionsForTesting() -> Bool {
        layoutFollowUpCoordinator.hasActivePendingReparentFocusSuppressions
    }
#endif

    func flushWorkspaceWindowLayouts() {
        for window in NSApp.windows where window.isVisible {
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    func browserPortalAnchorReady(for browserPanel: BrowserPanel) -> Bool {
        let anchorView = browserPanel.portalAnchorView
        return
            anchorView.window != nil &&
            anchorView.superview != nil &&
            anchorView.bounds.width > 1 &&
            anchorView.bounds.height > 1
    }

    func browserPortalReady(for browserPanel: BrowserPanel) -> Bool {
        browserPortalAnchorReady(for: browserPanel) &&
            browserPanel.webView.window != nil &&
            browserPanel.webView.superview != nil &&
            BrowserWindowPortalRegistry.isWebView(browserPanel.webView, boundTo: browserPanel.portalAnchorView)
    }

    func browserSplitZoomExitFocusNeedsFollowUp(panelId: UUID) -> Bool {
        guard let browserPanel = browserPanel(for: panelId),
              let paneId = paneId(forPanelId: panelId),
              let tabId = surfaceIdFromPanelId(panelId) else {
            return false
        }
        let selectionConverged =
            bonsplitController.focusedPaneId == paneId &&
            bonsplitController.selectedTab(inPane: paneId)?.id == tabId
        return !selectionConverged || !browserPortalAnchorReady(for: browserPanel)
    }

    /// Reconcile remaining terminal view geometries after split topology changes.
    /// This keeps AppKit bounds and Ghostty surface sizes in sync in the next runloop turn.
    func reconcileTerminalGeometryPass() -> Bool {
        var needsFollowUpPass = false
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()

        // Flush pending AppKit layout first so terminal-host bounds reflect latest split topology.
        for window in NSApp.windows where window.isVisible {
            window.contentView?.layoutSubtreeIfNeeded()
        }

        for panel in panels.values {
            guard let terminalPanel = panel as? TerminalPanel else { continue }
            // Mirror-rendered window-tab panels are driven by the in-tab mirror
            // view, not the workspace; never reattach/refresh their dismantled
            // hostedView here (matches the visibility/follow-up skips, and avoids
            // a non-converging layout follow-up loop during zoom).
            if remoteTmuxWindowMirrors[terminalPanel.id] != nil { continue }
            guard visiblePanelIds.contains(terminalPanel.id) else { continue }
            let hostedView = terminalPanel.hostedView
            let hasUsableBounds = hostedView.bounds.width > 1 && hostedView.bounds.height > 1
            let hasSurface = terminalPanel.surface.surface != nil
            let isAttached = terminalPanel.surface.isViewInWindow && hostedView.superview != nil

            // Split close/reparent churn can transiently detach a surviving terminal view.
            // Force one SwiftUI representable update so the portal binding reattaches it.
            if !isAttached || !hasUsableBounds || !hasSurface {
                terminalPanel.requestViewReattach()
                needsFollowUpPass = true
            }

            hostedView.reconcileGeometryNow()
            // Re-check surface after reconcileGeometryNow() which can trigger AppKit
            // layout and view lifecycle changes that free surfaces (#432).
            if terminalPanel.surface.surface != nil {
                terminalPanel.surface.forceRefresh()
            }
            if terminalPanel.surface.surface == nil, isAttached && hasUsableBounds {
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
                needsFollowUpPass = true
            }
        }

        return needsFollowUpPass
    }

#if DEBUG
    func setRestoredAgentSnapshotForTesting(_ snapshot: SessionRestorableAgentSnapshot, panelId: UUID) {
        restoredAgentSnapshotsByPanelId[panelId] = snapshot
        invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
    }

    func restoredAgentSnapshotForTesting(panelId: UUID) -> SessionRestorableAgentSnapshot? {
        restoredAgentSnapshotsByPanelId[panelId]
    }

    func setRestoredAgentAutoResumePendingForTesting(_ isPending: Bool, panelId: UUID) {
        if isPending {
            restoredAgentResumeStatesByPanelId[panelId] = .awaitingAutoResumeCommand
        } else {
            restoredAgentResumeStatesByPanelId.removeValue(forKey: panelId)
        }
    }

    func restoredAgentAutoResumePendingForTesting(panelId: UUID) -> Bool {
        restoredAgentResumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand
    }
#endif

    func scheduleTerminalGeometryReconcile() {
        layoutFollowUpCoordinator.scheduleTerminalGeometryReconcile()
    }

    // `internal` (not `private`): also read by the `AgentHibernationHosting`
    // conformance in `Workspace+AgentHibernationHosting.swift`.
    func renderedVisiblePanelIdsForCurrentLayout() -> Set<UUID> {
        guard layoutFollowUpCoordinator.portalRenderingEnabled else { return [] }
        // Canvas mode renders one panel per canvas pane — its selected tab.
        // Background tabs are unmounted, so reporting them as rendered makes
        // the terminal window portal float them at stale frames (chromeless
        // slivers). Offscreen clipping of the selected tabs is the canvas
        // viewport's job.
        if layoutMode == .canvas {
            return Set(canvasModel.layout.panes.map(\.selectedPanelId.rawValue))
        }
        let renderedPaneIds = bonsplitController.zoomedPaneId.map { [$0] } ?? bonsplitController.allPaneIds
        var visiblePanelIds: Set<UUID> = []

        for paneId in renderedPaneIds {
            let selectedTab = bonsplitController.selectedTab(inPane: paneId) ?? bonsplitController.tabs(inPane: paneId).first
            guard let selectedTab,
                  let panelId = panelIdFromSurfaceId(selectedTab.id),
                  panels[panelId] != nil else {
                continue
            }
            visiblePanelIds.insert(panelId)
        }

        if let focusedPanelId,
           panels[focusedPanelId] != nil,
           let focusedPaneId = paneId(forPanelId: focusedPanelId),
           renderedPaneIds.contains(where: { $0.id == focusedPaneId.id }) {
            visiblePanelIds.insert(focusedPanelId)
        }

        return visiblePanelIds
    }

    /// Forwards to ``AgentHibernationCoordinator/agentHibernationVisiblePanelIdsForCurrentLayout()``.
    func agentHibernationVisiblePanelIdsForCurrentLayout() -> Set<UUID> {
        agentHibernationCoordinator.agentHibernationVisiblePanelIdsForCurrentLayout()
    }

    @discardableResult
    func reconcileTerminalPortalVisibilityForCurrentRenderedLayout() -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()
        var didChange = agentHibernationAutoResumePresentationVisible
            ? resumeVisibleAgentHibernationPanels(panelIds: visiblePanelIds)
            : false

        for panel in panels.values {
            guard let terminalPanel = panel as? TerminalPanel else { continue }
            // A multi-pane remote-tmux window-tab is rendered by its
            // RemoteTmuxWindowMirrorView (its own panel's surface is not mounted),
            // so the workspace must not drive that panel's portal here.
            if remoteTmuxWindowMirrors[terminalPanel.id] != nil { continue }
            let shouldBeVisible = visiblePanelIds.contains(terminalPanel.id)
            if terminalPanel.hostedView.debugPortalVisibleInUI != shouldBeVisible {
                terminalPanel.hostedView.setVisibleInUI(shouldBeVisible)
                didChange = true
            }
            let shouldBeActive = shouldBeVisible && focusedPanelId == terminalPanel.id
            if terminalPanel.hostedView.debugPortalActive != shouldBeActive {
                terminalPanel.hostedView.setActive(shouldBeActive)
                didChange = true
            }
            TerminalWindowPortalRegistry.updateEntryVisibility(
                for: terminalPanel.hostedView,
                visibleInUI: shouldBeVisible
            )
        }

        return didChange
    }

    func terminalPortalVisibilityNeedsFollowUp() -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()

        for panel in panels.values {
            guard let terminalPanel = panel as? TerminalPanel else { continue }
            // Skip mirror-rendered window-tab panels (see reconcile above).
            if remoteTmuxWindowMirrors[terminalPanel.id] != nil { continue }
            let shouldBeVisible = visiblePanelIds.contains(terminalPanel.id)
            let hostedView = terminalPanel.hostedView

            if shouldBeVisible {
                if hostedView.isHidden || !terminalPanel.surface.isViewInWindow || hostedView.superview == nil {
                    return true
                }
            } else if !hostedView.isHidden {
                return true
            }
        }

        return false
    }

#if DEBUG
    @discardableResult
    func debugReconcileTerminalPortalVisibilityForTesting() -> Bool {
        reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
    }
#endif

    @discardableResult
    func reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason: String) -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()
        var didChange = false

        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            // Canvas-inline-hosted webviews live in the pane hierarchy; portal
            // rebinds/refreshes here would steal them back into the portal.
            if browserPanel.canvasInlineHostingActive { continue }
            let shouldBeVisible = visiblePanelIds.contains(browserPanel.id)
            let anchorView = browserPanel.portalAnchorView
            let snapshot = BrowserWindowPortalRegistry.debugSnapshot(for: browserPanel.webView)
            if shouldBeVisible {
                if snapshot?.visibleInUI == false {
                    BrowserWindowPortalRegistry.updateEntryVisibility(
                        for: browserPanel.webView,
                        visibleInUI: true,
                        zPriority: 2
                    )
                    didChange = true
                }
                let anchorReady = browserPortalAnchorReady(for: browserPanel)
                let portalReady = browserPortalReady(for: browserPanel)
                if anchorReady && !portalReady {
                    BrowserWindowPortalRegistry.synchronizeForAnchor(anchorView)
                    if browserPortalReady(for: browserPanel) {
                        BrowserWindowPortalRegistry.refresh(
                            webView: browserPanel.webView,
                            reason: reason
                        )
                        didChange = true
                    }
                } else if anchorReady && snapshot?.containerHidden == true {
                    BrowserWindowPortalRegistry.refresh(
                        webView: browserPanel.webView,
                        reason: reason
                    )
                    didChange = true
                }
            } else {
                let portalNeedsHide =
                    snapshot?.visibleInUI == true ||
                    snapshot?.containerHidden == false
                if portalNeedsHide {
                    if snapshot?.visibleInUI == true {
                        BrowserWindowPortalRegistry.updateEntryVisibility(
                            for: browserPanel.webView,
                            visibleInUI: false,
                            zPriority: 0
                        )
                    }
                    BrowserWindowPortalRegistry.hide(
                        webView: browserPanel.webView,
                        source: reason
                    )
                    didChange = true
                }
            }
        }

        return didChange
    }

    func browserPortalVisibilityNeedsFollowUp() -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()

        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            guard visiblePanelIds.contains(browserPanel.id) else { continue }
            let anchorView = browserPanel.portalAnchorView
            let anchorReady =
                anchorView.window != nil &&
                anchorView.superview != nil &&
                anchorView.bounds.width > 1 &&
                anchorView.bounds.height > 1
            if !anchorReady ||
                browserPanel.webView.window == nil ||
                browserPanel.webView.superview == nil ||
                !BrowserWindowPortalRegistry.isWebView(browserPanel.webView, boundTo: anchorView) {
                return true
            }
        }

        return false
    }

    /// Forces a post-move terminal refresh. Forwards to
    /// ``WorkspaceLayoutFollowUpCoordinator/scheduleMovedTerminalRefresh(panelId:)``,
    /// which runs the immediate pass plus a Clock-delayed second pass (replacing
    /// the legacy `DispatchQueue.main.asyncAfter`) and drives the actual reattach
    /// + geometry refresh through ``WorkspaceLayoutFollowUpHosting``.
    func scheduleMovedTerminalRefresh(panelId: UUID) {
        layoutFollowUpCoordinator.scheduleMovedTerminalRefresh(panelId: panelId)
    }

    @discardableResult
    func duplicateBrowserToRight(panelId: UUID, focus: Bool = true) -> BrowserPanel? {
        guard let anchorTabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId),
              let browser = browserPanel(for: panelId) else { return nil }
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        guard let newPanel = newBrowserSurface(
            inPane: paneId,
            url: browser.currentURLForTabDuplication,
            focus: focus,
            preferredProfileID: browser.profileID,
            omnibarVisible: browser.isOmnibarVisible,
            bypassRemoteProxy: browser.bypassesRemoteWorkspaceProxyForTabDuplication
        ) else { return nil }
        newPanel.setMuted(browser.isMuted)
        syncBrowserAudioMuteStateForPanel(newPanel.id, browserPanel: newPanel)
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex, focus: focus)
        return newPanel
    }

    /// Resolves the bonsplit "Move Tab To…" destinations for `tabId` through the
    /// context-menu coordinator, passing the localized "New Workspace" label
    /// resolved app-side (`String(localized:)` must bind to the app bundle, not
    /// the package bundle, to keep non-English translations).
    private func contextMenuMoveDestinations(for tabId: TabID) -> [TabContextMoveDestination] {
        contextMenuCoordinator.moveDestinations(
            for: tabId,
            newWorkspaceTitle: String(localized: "command.newWorkspace.title", defaultValue: "New Workspace")
        )
    }

    /// Forwards to ``WorkspaceDropCoordinator/handleFilePreviewDrop`` indirectly
    /// via the resolved payload. Kept as a `Workspace` method because the
    /// browser/terminal pane drop target views call it directly with the live
    /// `FilePreviewDragEntry`; the routing now lives in the coordinator, reached
    /// through the ``WorkspaceDropHosting`` seam.
    func handleFilePreviewDrop(
        entry: FilePreviewDragEntry,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        workspaceDrop.handleFileDrop(
            payload: WorkspaceFileDropPayload(filePath: entry.filePath),
            destination: destination
        )
    }

    /// Forwards to ``WorkspaceDropCoordinator/handleExternalFileDrop(_:)``. Kept
    /// as a `Workspace` method because the bonsplit `onExternalFileDrop` handler
    /// and the pane drop target views call it directly.
    func handleExternalFileDrop(_ request: BonsplitController.ExternalFileDropRequest) -> Bool {
        workspaceDrop.handleExternalFileDrop(request)
    }

    /// Relaxed from `private` to `internal` so the lifted drop-routing seam
    /// conformance (`Workspace+WorkspaceDropHosting.swift`) can call it for the
    /// file-drop split branches; the body is the unchanged markdown-vs-preview
    /// split-creation primitive, which stays app-side (Wave-4 surface creation).
    @discardableResult
    func splitPaneWithFileSurface(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        filePath: String
    ) -> (any Panel)? {
        if MarkdownPanelFileLinkResolver.isMarkdownPathLike(filePath) {
            return splitPaneWithMarkdown(
                targetPane: paneId,
                orientation: orientation,
                insertFirst: insertFirst,
                filePath: filePath
            )
        }
        return splitPaneWithFilePreview(
            targetPane: paneId,
            orientation: orientation,
            insertFirst: insertFirst,
            filePath: filePath
        )
    }

    /// Split `paneId` and place a brand-new terminal in the resulting pane.
    /// Used by the session-index drop path; mirrors `newTerminalSplit(from:...)` but
    /// targets a destination pane directly rather than inheriting from a source panel.
    @discardableResult
    func splitPaneWithNewTerminal(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        workingDirectory: String?,
        initialInput: String?,
        remoteStartupCommand: String? = nil
    ) -> TerminalPanel? {
        var inheritedConfig = inheritedTerminalConfig(inPane: paneId)
        let startupCommand = surfaceCreation.normalizedExplicitInitialCommand(remoteStartupCommand)
        let effectiveStartupEnvironment = terminalStartupEnvironment(
            base: startupEnvironmentMergingWorkspaceEnvironment([:]),
            remoteStartupCommand: startupCommand
        )
        inheritedConfig = surfaceCreation.configHoldingPaneAfterStartupCommand(
            inheritedConfig: inheritedConfig,
            hasStartupCommand: startupCommand != nil
        )

        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: startupCommand,
            initialInput: initialInput,
            additionalEnvironment: effectiveStartupEnvironment
        )
        configureNewTerminalPanel(newPanel)
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        if startupCommand != nil {
            trackRemoteTerminalSurface(newPanel.id)
        }
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)

        let newTab = Bonsplit.Tab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal.rawValue,
            isDirty: newPanel.isDirty,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = newPanel.id

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            if startupCommand != nil {
                untrackRemoteTerminalSurface(newPanel.id)
            }
            terminalInheritanceFontPointsByPanelId.removeValue(forKey: newPanel.id)
            return nil
        }
        publishCmuxSplitCreated(newPaneId, sourcePaneId: paneId, orientation: orientation, surfaceId: newPanel.id, kind: "terminal", origin: "terminal_split", focused: true)

        bonsplitController.selectTab(newTab.id)
        newPanel.focus()
        return newPanel
    }

    /// The resolved new-workspace fork-launch descriptor. Lifted to
    /// `CMUXAgentLaunch`; kept as a `typealias` so existing
    /// `Workspace.AgentConversationForkWorkspaceLaunch` references stay
    /// byte-identical. The fork orchestration that produces and consumes it
    /// stays app-side (it drives the live bonsplit tree and `TabManager`).
    typealias AgentConversationForkWorkspaceLaunch = CMUXAgentLaunch.AgentConversationForkWorkspaceLaunch

    /// Forwards to ``AgentForkCoordinator/forkAgentWorkspaceLaunch(fromPanelId:snapshot:)``.
    func forkAgentWorkspaceLaunch(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot
    ) -> AgentConversationForkWorkspaceLaunch? {
        agentForkCoordinator.forkAgentWorkspaceLaunch(fromPanelId: panelId, snapshot: snapshot)
    }

    /// Forwards to ``AgentForkCoordinator/forkAgentConversation(fromPanelId:snapshot:direction:)``.
    @discardableResult
    func forkAgentConversation(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        direction: SplitDirection
    ) -> TerminalPanel? {
        agentForkCoordinator.forkAgentConversation(
            fromPanelId: panelId,
            snapshot: snapshot,
            direction: direction
        )
    }

    /// Forwards to ``AgentForkHosting/agentForkWorkingDirectory(panelId:snapshot:)``
    /// (the host conformance), which is the lifted home of this resolution.
    func forkAgentWorkingDirectory(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot
    ) -> String? {
        agentForkWorkingDirectory(panelId: panelId, snapshot: snapshot)
    }

    /// Forwards to ``AgentForkCoordinator/canForkAgentConversationFromPanel(_:)``.
    /// Synchronous availability check used by the tab right-click context menu to decide
    /// whether to surface the Fork Conversation item for a given anchor tab. Restricted to
    /// `.supportedWithoutProbe` so we never offer an item that may quietly fail; agents
    /// requiring a probe (e.g. shell-launched OpenCode) stay reachable from the command
    /// palette path that performs that probe first.
    func canForkAgentConversationFromPanel(_ panelId: UUID) -> Bool {
        agentForkCoordinator.canForkAgentConversationFromPanel(panelId)
    }

    /// Forwards to ``AgentForkHosting/agentForkableSnapshot(panelId:)`` (the host
    /// conformance), which is the lifted home of this lookup.
    /// Snapshot used by the right-click fork path. Prefers the workspace's restored snapshot
    /// (filled on session restore / hibernation), then falls back to the process-wide
    /// `SharedLiveAgentIndex`. The shared index loads the on-disk hook session store off the
    /// main actor (it runs `sysctl(KERN_PROCARGS2)` per live record for live-PID filtering,
    /// which is too expensive to do synchronously during SwiftUI menu evaluation) and a
    /// single load serves every workspace. The Workspace tracks the shared store's
    /// `@Observable` snapshots via `withObservationTracking` in its initializer so that
    /// when a refresh lands, it bumps `liveAgentIndexRevision`, ContentView re-renders, and
    /// bonsplit's TabBarView re-evaluates the menu state — Fork Conversation appears the
    /// moment the index is loaded without requiring a second right-click.
    func forkableAgentSnapshot(forPanelId panelId: UUID) -> SessionRestorableAgentSnapshot? {
        agentForkableSnapshot(panelId: panelId)
    }

    /// Forwards to ``AgentForkCoordinator/forkAgentConversationToNewTab(fromPanelId:snapshot:anchorTabId:paneId:)``.
    /// Fork the panel's agent conversation into a brand-new sibling tab placed immediately
    /// to the right of `anchorTabId` in `paneId`. Uses the same `claude --resume --fork-session`
    /// startup input the existing split/new-workspace forks rely on, so divergence is owned by
    /// the agent itself (Claude / Codex / OpenCode) instead of any cmux-side history copy.
    @discardableResult
    func forkAgentConversationToNewTab(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        anchorTabId: TabID,
        paneId: PaneID
    ) -> TerminalPanel? {
        agentForkCoordinator.forkAgentConversationToNewTab(
            fromPanelId: panelId,
            snapshot: snapshot,
            anchorTabId: anchorTabId,
            paneId: paneId
        )
    }

    /// Relaxed from `private` to `internal` so the lifted fork host conformance
    /// (`Workspace+AgentForkHosting.swift`) can reach it; the body is unchanged.
    static func firstNonEmptyPath(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    /// Forwards to ``WorkspaceDropCoordinator/handleExternalTabDrop(_:)``. Kept
    /// as a `Workspace` method because the bonsplit `onExternalTabDrop` handler
    /// and the portal pane drop call it directly. The session/file-registry
    /// consumption, the cross-window-move decomposition, and the DEBUG tracing
    /// now live in the coordinator, reached through the ``WorkspaceDropHosting``
    /// seam this `Workspace` conforms to.
    func handleExternalTabDrop(_ request: BonsplitController.ExternalTabDropRequest) -> Bool {
        workspaceDrop.handleExternalTabDrop(request)
    }

}

// MARK: - BonsplitDelegate

// MARK: - PaneTreeHosting (legacy @Published observer hooks)

// `SurfaceCreationHosting` (CmuxWorkspaces) supplies the live panel/Ghostty reads
// and writes for the coordinator's inheritance walk; the protocol carries the
// per-member contract. `probeInheritanceCandidate` pins the panel/surface once
// (the legacy single pin) for both C reads; `commitInheritanceSelection` applies
// the writes in the legacy order (seed → remember → record-last).
/// `Workspace` supplies the sidebar directory/order projection's live-state
/// reads. The conforming members live with the other sidebar projection code in
/// the main class body.
extension Workspace: SidebarMetadataHosting {}

extension Workspace: SurfaceCreationHosting {
    func configInheritanceCandidatePanelIds(preferredPanelId: UUID?, inPane preferredPaneId: PaneID?) -> [UUID] {
        terminalPanelConfigInheritanceCandidates(preferredPanelId: preferredPanelId, inPane: preferredPaneId).map(\.id)
    }

    func probeInheritanceCandidate(panelId: UUID) -> SurfaceInheritanceCandidateProbe? {
        guard let terminalPanel = terminalPanel(for: panelId) else { return nil }
        let surface = terminalPanel.surface
        guard let sourceSurface = surface.surface else { return nil }
        defer { withExtendedLifetime((terminalPanel, surface)) {} }
        return SurfaceInheritanceCandidateProbe(
            inheritedConfig: cmuxInheritedSurfaceConfig(sourceSurface: sourceSurface, context: GHOSTTY_SURFACE_CONTEXT_SPLIT),
            rootedFontPoints: terminalInheritanceFontPointsByPanelId[panelId],
            runtimeFontPoints: cmuxCurrentSurfaceFontSizePoints(sourceSurface)
        )
    }

    func commitInheritanceSelection(panelId: UUID, rootedFontPoints: Float?, finalConfigFontPoints: Float) {
        if let rootedFontPoints { terminalInheritanceFontPointsByPanelId[panelId] = rootedFontPoints }
        if let terminalPanel = terminalPanel(for: panelId) { rememberTerminalConfigInheritanceSource(terminalPanel) }
        if finalConfigFontPoints > 0 { lastTerminalConfigInheritanceFontPoints = finalConfigFontPoints }
    }

    var lastKnownInheritanceFontPoints: Float? { lastTerminalConfigInheritanceFontPoints }

    func logInheritanceFallback(fontPoints: Float) {
#if DEBUG
        cmuxDebugLog("zoom.inherit fallback=lastKnownFont context=split font=\(String(format: "%.2f", fontPoints))")
#endif
    }

    // MARK: Create-tab live state
    //
    // `focusedBonsplitPaneId`, `focusedPanelId`, `reorderTab(_:toIndex:)`,
    // `publishCmuxSurfaceCreated`, `focusPane(_:)`, `selectTab(_:)`, and
    // `applyTabSelection(tabId:inPane:)` are shared witnesses already implemented
    // for the `SplitMoveReorderHosting`/lifecycle conformances; they satisfy the
    // identical `SurfaceCreationHosting` requirements from those single
    // implementations. The members below are the create-tab-specific witnesses.

    var focusedTerminalHostedView: AnyObject? { focusedTerminalPanel?.hostedView }

    func registerProjectPanel(projectURL: URL) -> SurfaceTabDescriptor {
        let projectPanel = ProjectPanel(projectURL: projectURL)
        panels[projectPanel.id] = projectPanel
        panelTitles[projectPanel.id] = projectPanel.displayTitle
        return SurfaceTabDescriptor(
            id: projectPanel.id,
            displayTitle: projectPanel.displayTitle,
            displayIcon: projectPanel.displayIcon,
            isDirty: false
        )
    }

    func createSurfaceTab(descriptor: SurfaceTabDescriptor, kind: String, inPane paneId: PaneID) -> TabID? {
        guard let newTabId = bonsplitController.createTab(
            title: descriptor.displayTitle,
            icon: descriptor.displayIcon,
            kind: kind,
            isDirty: descriptor.isDirty,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            return nil
        }
        surfaceIdToPanelId[newTabId] = descriptor.id
        return newTabId
    }

    func preserveSurfaceFocusAfterNonFocusSplit(preferredPanelId: UUID?, splitPanelId: UUID, previousHostedView: AnyObject?) {
        preserveFocusAfterNonFocusSplit(
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId,
            previousHostedView: previousHostedView as? GhosttySurfaceScrollView
        )
    }

    func discardPanelRegistration(id: UUID) {
        panels.removeValue(forKey: id)
        panelTitles.removeValue(forKey: id)
    }

    func reloadProjectPanel(id: UUID) {
        (panels[id] as? ProjectPanel)?.reload()
    }

    // MARK: Markdown create + split live state
    //
    // `paneId(forPanelId:)`, `focusedBonsplitPaneId`, `focusedPanelId`,
    // `createSurfaceTab`, `reorderTab`, `publishCmuxSurfaceCreated`, `focusPane`,
    // `selectTab`, `applyTabSelection`, `preserveSurfaceFocusAfterNonFocusSplit`,
    // and `discardPanelRegistration` are shared witnesses already implemented
    // above or for sibling conformances. The members below are the markdown
    // create/split-specific witnesses.

    func registerMarkdownPanel(filePath: String, fontSize: Double?) -> SurfaceTabDescriptor {
        let markdownPanel = MarkdownPanel(workspaceId: id, filePath: filePath, fontSize: fontSize)
        panels[markdownPanel.id] = markdownPanel
        panelTitles[markdownPanel.id] = markdownPanel.displayTitle
        return SurfaceTabDescriptor(
            id: markdownPanel.id,
            displayTitle: markdownPanel.displayTitle,
            displayIcon: markdownPanel.displayIcon,
            isDirty: markdownPanel.isDirty
        )
    }

    func splitSurface(
        _ paneId: PaneID,
        orientation: SplitOrientation,
        withTab descriptor: SurfaceTabDescriptor,
        kind: String,
        insertFirst: Bool
    ) -> PaneID? {
        let newTab = Bonsplit.Tab(
            title: descriptor.displayTitle,
            icon: descriptor.displayIcon,
            kind: kind,
            isDirty: descriptor.isDirty,
            isLoading: false,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = descriptor.id

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(
            paneId,
            orientation: orientation,
            withTab: newTab,
            insertFirst: insertFirst
        ) else {
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            return nil
        }
        return newPaneId
    }

    func suppressReparentFocusUntilLayoutFollowUp(_ hostedView: AnyObject?, reason: String) {
        suppressReparentFocusUntilLayoutFollowUp(
            hostedView as? GhosttySurfaceScrollView,
            reason: reason
        )
    }

    func focusSurfacePanel(_ panelId: UUID) {
        focusPanel(panelId)
    }

    func selectSurfaceTab(panelId: UUID) {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        bonsplitController.selectTab(tabId)
    }

    func installMarkdownPanelSubscription(id: UUID) {
        guard let markdownPanel = panels[id] as? MarkdownPanel else { return }
        installMarkdownPanelSubscription(markdownPanel)
    }

    // MARK: FilePreview create + split live state
    //
    // `focusedBonsplitPaneId`, `focusedPanelId`, `focusedTerminalHostedView`,
    // `createSurfaceTab`, `reorderTab`, `publishCmuxSurfaceCreated`,
    // `publishCmuxSplitCreated`, `splitSurface`, `selectSurfaceTab`, `focusPane`,
    // `selectTab`, `applyTabSelection`, `preserveSurfaceFocusAfterNonFocusSplit`,
    // and `discardPanelRegistration` are shared witnesses already implemented
    // above or for sibling conformances. The members below are the file-preview
    // create/split-specific witnesses. `registerFilePreviewPanel` resolves the
    // tab icon app-side (the legacy file-preview bodies passed
    // `RenderableSystemSymbol.resolvedSurfaceTabIcon(displayIcon)` to bonsplit,
    // unlike the project/markdown registrations which pass the raw `displayIcon`).

    func registerFilePreviewPanel(filePath: String) -> SurfaceTabDescriptor {
        let filePreviewPanel = FilePreviewPanel(workspaceId: id, filePath: filePath)
        panels[filePreviewPanel.id] = filePreviewPanel
        panelTitles[filePreviewPanel.id] = filePreviewPanel.displayTitle
        return SurfaceTabDescriptor(
            id: filePreviewPanel.id,
            displayTitle: filePreviewPanel.displayTitle,
            displayIcon: RenderableSystemSymbol.resolvedSurfaceTabIcon(filePreviewPanel.displayIcon),
            isDirty: filePreviewPanel.isDirty
        )
    }

    func focusFilePreviewPanel(id: UUID) {
        (panels[id] as? FilePreviewPanel)?.focus()
    }

    func installFilePreviewPanelSubscription(id: UUID) {
        guard let filePreviewPanel = panels[id] as? FilePreviewPanel else { return }
        installFilePreviewPanelSubscription(filePreviewPanel)
    }

    // MARK: Agent-session create live state
    //
    // `currentDirectory`, `focusedBonsplitPaneId`, `focusedPanelId`,
    // `focusedTerminalHostedView`, `createSurfaceTab`, `reorderTab`,
    // `publishCmuxSurfaceCreated`, `focusPane`, `selectTab`, `applyTabSelection`,
    // `preserveSurfaceFocusAfterNonFocusSplit`, and `discardPanelRegistration` are
    // already implemented above or for sibling conformances (`currentDirectory` is
    // the workspace's stored projection). The members below are the agent-session
    // create-specific witnesses. The provider/renderer arrive as their frozen
    // `rawValue` strings; both always round-trip for live callers, so the failable
    // inits below cannot take their backstops in practice.

    func registerAgentSessionPanel(
        providerIDRawValue: String,
        rendererKindRawValue: String,
        workingDirectory: String
    ) -> SurfaceTabDescriptor {
        let providerID = AgentSessionProviderID(rawValue: providerIDRawValue) ?? .codex
        let rendererKind = AgentSessionRendererKind(rawValue: rendererKindRawValue) ?? .react
        let agentPanel = AgentSessionPanel(
            workspaceId: id,
            rendererKind: rendererKind,
            initialProviderID: providerID,
            workingDirectory: workingDirectory
        )
        panels[agentPanel.id] = agentPanel
        panelTitles[agentPanel.id] = agentPanel.displayTitle
        if !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panelDirectories[agentPanel.id] = workingDirectory
        }
        return SurfaceTabDescriptor(
            id: agentPanel.id,
            displayTitle: agentPanel.displayTitle,
            displayIcon: agentPanel.displayIcon,
            isDirty: agentPanel.isDirty
        )
    }

    func focusAgentSessionPanel(id: UUID) {
        (panels[id] as? AgentSessionPanel)?.focus()
    }

    func installAgentSessionPanelSubscription(id: UUID) {
        guard let agentPanel = panels[id] as? AgentSessionPanel else { return }
        installAgentSessionPanelSubscription(agentPanel)
    }

    // MARK: Extension-browser create live state
    //
    // `focusedBonsplitPaneId`, `createSurfaceTab`, `publishCmuxSurfaceCreated`,
    // `focusPane`, `selectTab`, `applyTabSelection`, and `discardPanelRegistration`
    // are already implemented above or for sibling conformances. The members below
    // are the extension-browser create-specific witnesses.

    func registerExtensionBrowserPanel(title: String) -> SurfaceTabDescriptor {
        let extensionBrowserPanel = CMUXSidebarExtensionBrowserPanel(title: title)
        panels[extensionBrowserPanel.id] = extensionBrowserPanel
        panelTitles[extensionBrowserPanel.id] = extensionBrowserPanel.displayTitle
        return SurfaceTabDescriptor(
            id: extensionBrowserPanel.id,
            displayTitle: extensionBrowserPanel.displayTitle,
            displayIcon: extensionBrowserPanel.displayIcon,
            isDirty: false
        )
    }

    func focusExtensionBrowserPanel(id: UUID) {
        (panels[id] as? CMUXSidebarExtensionBrowserPanel)?.focus()
    }

    // MARK: Right-sidebar-tool create live state
    //
    // `focusedBonsplitPaneId`, `focusedPanelId`, `focusedTerminalHostedView`,
    // `createSurfaceTab`, `reorderTab`, `publishCmuxSurfaceCreated`,
    // `focusSurfacePanel`, `preserveSurfaceFocusAfterNonFocusSplit`, and
    // `discardPanelRegistration` are already implemented above or for sibling
    // conformances. The member below is the right-sidebar-tool create-specific
    // witness. The mode arrives as its frozen `rawValue` string; it always
    // round-trips for live callers, so the failable init's backstop is unreachable.

    func registerRightSidebarToolPanel(modeRawValue: String) -> SurfaceTabDescriptor {
        let mode = RightSidebarMode(rawValue: modeRawValue) ?? .files
        let toolPanel = RightSidebarToolPanel(workspace: self, mode: mode)
        panels[toolPanel.id] = toolPanel
        panelTitles[toolPanel.id] = toolPanel.displayTitle
        return SurfaceTabDescriptor(
            id: toolPanel.id,
            displayTitle: toolPanel.displayTitle,
            displayIcon: toolPanel.displayIcon,
            isDirty: false
        )
    }
}

extension Workspace: PaneTreeHosting {
    /// Drives the `panelsPublisher` Combine bridge at the exact `willSet`
    /// timing the legacy `@Published panels` used. SwiftUI re-render no longer
    /// needs a manual signal here: `panels` forwards to the `@Observable`
    /// `paneTree.panels`, so a view reading `workspace.panels` is invalidated by
    /// `paneTree`'s own Observation when the underlying store mutates.
    func panelsWillChange(to newValue: [UUID: any Panel]) {
        panelsPublisher.send(newValue)
    }

    /// Drives the `paneLayoutVersionPublisher` Combine bridge; same contract.
    func paneLayoutVersionWillChange(to newValue: Int) {
        paneLayoutVersionPublisher.send(newValue)
    }
}

extension Workspace: BonsplitDelegate {
    @MainActor
    private func shouldCloseWorkspaceOnLastSurface(for tabId: TabID) -> Bool {
        let manager = owningTabManager ?? hostEnvironment?.tabManagerFor(tabId: id) ?? hostEnvironment?.tabManager
        guard panels.count <= 1,
              panelIdFromSurfaceId(tabId) != nil,
              let manager,
              manager.tabs.contains(where: { $0.id == id }) else {
            return false
        }
        return true
    }

    @MainActor
    /// - Parameter nameOverride: when non-nil, the dialog names this instead of
    ///   the panel title. The mirror window-tab path passes the LIVE foreground
    ///   command here so the dialog says "sleep" the instant the close fires —
    ///   the tab's own title (tmux's window name) only catches up to the
    ///   automatic-rename a beat later, which otherwise reads like the dialog is
    ///   naming a different tab.
    private func confirmClosePanel(for tabId: TabID, nameOverride: String? = nil) async -> Bool {
        let title = String(localized: "dialog.closeTab.title", defaultValue: "Close tab?")
        let panelName: String? = {
            // The panel-id-keyed candidates are read only when an override is
            // absent; mirror the legacy ordering by resolving the panel id (and
            // its title metadata) lazily after the override short-circuit.
            let panelId = panelIdFromSurfaceId(tabId)
            return splitLifecycle.closeConfirmationPanelName(
                nameOverride: nameOverride,
                customTitle: panelId.flatMap { panelCustomTitles[$0] },
                title: panelId.flatMap { panelTitles[$0] },
                directory: panelId.flatMap { panelDirectories[$0] }
            )
        }()

        let message: String
        if let panelName {
            message = String(localized: "dialog.closeTab.messageNamed", defaultValue: "This will close \"\(panelName)\".")
        } else {
            message = String(localized: "dialog.closeTab.message", defaultValue: "This will close the current tab.")
        }

        if let confirmCloseHandler = (
            owningTabManager
            ?? hostEnvironment?.tabManagerFor(tabId: id)
            ?? hostEnvironment?.tabManager
        )?.workspaceClosing.confirmCloseHandler {
            return confirmCloseHandler(title, message, false)
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "dialog.closeTab.cancel", defaultValue: "Cancel"))

        if let closeButton = alert.buttons.first {
            closeButton.keyEquivalent = "\r"
            closeButton.keyEquivalentModifierMask = []
            alert.window.defaultButtonCell = closeButton.cell as? NSButtonCell
            alert.window.initialFirstResponder = closeButton
        }
        if let cancelButton = alert.buttons.dropFirst().first {
            cancelButton.keyEquivalent = "\u{1b}"
        }

        // Prefer a sheet if we can find a window, otherwise fall back to modal.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        }

        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Apply the side-effects of selecting a tab (unfocus others, focus this panel, update state).
    /// bonsplit doesn't always emit didSelectTab for programmatic selection paths (e.g. createTab).
    func applyTabSelection(
        tabId: TabID,
        inPane pane: PaneID,
        reassertAppKitFocus: Bool = true,
        focusIntent: PanelFocusIntent? = nil,
        resumeHibernatedAgent: Bool? = nil,
        previousTerminalHostedView: GhosttySurfaceScrollView? = nil
    ) {
        pendingTabSelection = PendingTabSelectionRequest(
            tabId: tabId,
            pane: pane,
            reassertAppKitFocus: reassertAppKitFocus,
            focusIntent: focusIntent,
            resumeHibernatedAgent: resumeHibernatedAgent,
            previousTerminalHostedView: previousTerminalHostedView
        )
        guard !isApplyingTabSelection else { return }
        isApplyingTabSelection = true
        defer {
            isApplyingTabSelection = false
            pendingTabSelection = nil
        }

        var iterations = 0
        while let request = pendingTabSelection {
            pendingTabSelection = nil
            iterations += 1
            if iterations > 8 { break }
            applyTabSelectionNow(
                tabId: request.tabId,
                inPane: request.pane,
                reassertAppKitFocus: request.reassertAppKitFocus,
                focusIntent: request.focusIntent,
                resumeHibernatedAgent: request.resumeHibernatedAgent,
                previousTerminalHostedView: request.previousTerminalHostedView
            )
        }
    }

    /// Hide browser portals for tabs that are no longer selected in the given pane.
    private func hideBrowserPortalsForDeselectedTabs(inPane pane: PaneID, selectedTabId: TabID) {
        for tab in bonsplitController.tabs(inPane: pane) {
            guard tab.id != selectedTabId else { continue }
            guard let panelId = panelIdFromSurfaceId(tab.id),
                  let browserPanel = panels[panelId] as? BrowserPanel else { continue }
            browserPanel.hideBrowserPortalView(source: "tabDeselected")
        }
    }

    private func applyTabSelectionNow(
        tabId: TabID,
        inPane pane: PaneID,
        reassertAppKitFocus: Bool,
        focusIntent: PanelFocusIntent?,
        resumeHibernatedAgent: Bool?,
        previousTerminalHostedView: GhosttySurfaceScrollView?
    ) {
        let previousFocusedPanelId = focusedPanelId
#if DEBUG
        let focusedPaneBefore = bonsplitController.focusedPaneId.map { String($0.id.uuidString.prefix(5)) } ?? "nil"
        let selectedTabBefore = bonsplitController.focusedPaneId
            .flatMap { bonsplitController.selectedTab(inPane: $0)?.id }
            .map { String($0.uuid.uuidString.prefix(5)) } ?? "nil"
        cmuxDebugLog(
            "focus.split.apply.begin workspace=\(id.uuidString.prefix(5)) " +
            "pane=\(pane.id.uuidString.prefix(5)) tab=\(tabId.uuid.uuidString.prefix(5)) " +
            "focusedPane=\(focusedPaneBefore) selectedTab=\(selectedTabBefore) " +
            "reassert=\(reassertAppKitFocus ? 1 : 0)"
        )
#endif
        if bonsplitController.allPaneIds.contains(pane) {
            if bonsplitController.focusedPaneId != pane {
                bonsplitController.focusPane(pane)
            }
            if bonsplitController.tabs(inPane: pane).contains(where: { $0.id == tabId }),
               bonsplitController.selectedTab(inPane: pane)?.id != tabId {
                bonsplitController.selectTab(tabId)
            }
        }

        let focusedPane: PaneID
        let selectedTabId: TabID
        if let currentPane = bonsplitController.focusedPaneId,
           let currentTabId = bonsplitController.selectedTab(inPane: currentPane)?.id {
            focusedPane = currentPane
            selectedTabId = currentTabId
        } else if bonsplitController.tabs(inPane: pane).contains(where: { $0.id == tabId }) {
            focusedPane = pane
            selectedTabId = tabId
            bonsplitController.focusPane(focusedPane)
            bonsplitController.selectTab(selectedTabId)
        } else {
            return
        }

        // Focus the selected panel, but keep the previously focused terminal active while a
        // newly created split terminal is still unattached.
        guard let selectedPanelId = panelIdFromSurfaceId(selectedTabId) else {
            return
        }
        let effectiveFocusedPanelId = effectiveSelectedPanelId(inPane: focusedPane) ?? selectedPanelId
        guard let panel = panels[effectiveFocusedPanelId] else {
            return
        }

        if debugStressPreloadSelectionDepth > 0 {
            if let terminalPanel = panel as? TerminalPanel {
                terminalPanel.requestViewReattach()
                scheduleTerminalGeometryReconcile()
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
            }
            return
        }

        let explicitFocusIntent = shouldTreatCurrentEventAsExplicitFocusIntent()
        if explicitFocusIntent {
            markExplicitFocusIntent(on: effectiveFocusedPanelId)
        }
        // Selecting a hibernated tab means the user is visiting it again. Resume by
        // default so sidebar/tab selection behaves the same as pressing Resume.
        let shouldResumeHibernatedAgent = resumeHibernatedAgent ?? true
        let activationIntent = focusIntent ?? panel.preferredFocusIntentForActivation()
        panel.prepareFocusIntentForActivation(activationIntent)
        let panelId = effectiveFocusedPanelId
        if let terminalPanel = panel as? TerminalPanel {
            if terminalPanel.isAgentHibernated, shouldResumeHibernatedAgent {
                _ = resumeAgentHibernation(panelId: panelId, focus: false)
            }
            AgentHibernationController.shared.recordTerminalFocus(workspaceId: id, panelId: panelId)
        }

        syncPinnedStateForTab(selectedTabId, panelId: selectedPanelId)
        if previousFocusedPanelId != panelId {
            syncUnreadBadgeStateForAllPanels()
        } else {
            syncUnreadBadgeStateForPanel(selectedPanelId)
        }

        // Unfocus all other panels
        for (id, p) in panels where id != effectiveFocusedPanelId {
            p.unfocus()
        }

        // Explicitly hide browser portals for deselected tabs in this pane.
        // Bonsplit's keepAllAlive mode hides non-selected tabs via SwiftUI .opacity(0),
        // but portal-hosted WKWebViews render at the window level in AppKit and are not
        // affected by SwiftUI opacity. Without an explicit hide, the deselected browser's
        // portal layer can remain visible above the newly selected tab.
        hideBrowserPortalsForDeselectedTabs(inPane: focusedPane, selectedTabId: selectedTabId)

        if let focusWindow = activationWindow(for: panel) {
            yieldForeignOwnedFocusIfNeeded(
                in: focusWindow,
                targetPanelId: panelId,
                targetIntent: activationIntent
            )
        }

        activatePanel(
            panel,
            focusIntent: activationIntent,
            reassertAppKitFocus: reassertAppKitFocus
        )
        let focusIntentAllowsBrowserOmnibarAutofocus =
            explicitFocusIntent ||
            TerminalController.socketCommandAllowsInAppFocusMutations()
        if let browserPanel = panel as? BrowserPanel,
           shouldAllowBrowserOmnibarAutofocus(for: activationIntent),
           previousFocusedPanelId != panelId || focusIntentAllowsBrowserOmnibarAutofocus {
            maybeAutoFocusBrowserAddressBarOnPanelFocus(browserPanel, trigger: .standard)
        }
        if let terminalPanel = panel as? TerminalPanel {
            rememberTerminalConfigInheritanceSource(terminalPanel)
        }

        // Converge AppKit first responder with bonsplit's selected tab in the focused pane.
        // Without this, keyboard input can remain on a different terminal than the blue tab indicator.
        if reassertAppKitFocus, let terminalPanel = panel as? TerminalPanel {
            if shouldMoveTerminalSurfaceFocus(for: activationIntent) {
                if !terminalPanel.hostedView.isSurfaceViewFirstResponder() {
#if DEBUG
                    let previousExists = previousTerminalHostedView != nil ? 1 : 0
                    cmuxDebugLog(
                        "focus.split.moveFocus workspace=\(id.uuidString.prefix(5)) " +
                        "panel=\(panelId.uuidString.prefix(5)) previousExists=\(previousExists) " +
                        "to=\(panelId.uuidString.prefix(5))"
                    )
#endif
                    terminalPanel.hostedView.moveFocus(from: previousTerminalHostedView)
                }
#if DEBUG
                cmuxDebugLog(
                    "focus.split.ensureFocus workspace=\(id.uuidString.prefix(5)) " +
                    "panel=\(panelId.uuidString.prefix(5)) pane=\(focusedPane.id.uuidString.prefix(5)) " +
                    "tab=\(selectedTabId.uuid.uuidString.prefix(5)) intent=\(String(describing: activationIntent))"
                )
#endif
                terminalPanel.hostedView.ensureFocus(for: id, surfaceId: panelId)
            }
        }

        if shouldRestoreFocusIntentAfterActivation(activationIntent) {
            _ = panel.restoreFocusIntent(activationIntent)
        }

        surfaceTabBarDirectory = configTrackingDirectory(for: panelId)

        // Update current directory if this is a terminal
        if let dir = panelDirectories[panelId] {
            currentDirectory = dir
        }
        gitBranch = panelGitBranches[panelId]
        pullRequest = panelPullRequests[panelId]

        // Broadcast the focus change. This is deferred + coalesced (not posted
        // synchronously) so the `@Published` mutations above settle before any
        // observer runs, and so a notification-driven focus cycle (command-palette
        // restore + cross-workspace handoff) cannot synchronously re-enter
        // applyTabSelectionNow and hang the main thread. See issue #5100.
        FocusSurfaceBroadcaster.shared.emit(
            FocusSurfaceBroadcaster.FocusSurfacePayload(
                workspaceId: self.id,
                panelId: panelId,
                explicitFocusIntent: explicitFocusIntent
            )
        )
        publishCmuxFocusedSelection(paneId: focusedPane, surfaceId: panelId, origin: "bonsplit_selection")
#if DEBUG
        let prevPanelShort = previousFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        cmuxDebugLog(
            "focus.split.apply.end workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) type=\(String(describing: type(of: panel))) " +
            "focusedPane=\(focusedPane.id.uuidString.prefix(5)) selectedTab=\(selectedTabId.uuid.uuidString.prefix(5)) " +
            "prevPanel=\(prevPanelShort)"
        )
#endif
    }

    private func activatePanel(
        _ panel: any Panel,
        focusIntent: PanelFocusIntent,
        reassertAppKitFocus: Bool
    ) {
        if let terminalPanel = panel as? TerminalPanel {
            let shouldFocusTerminalSurface = shouldMoveTerminalSurfaceFocus(for: focusIntent)
            terminalPanel.surface.setFocus(shouldFocusTerminalSurface)
            terminalPanel.hostedView.setActive(true)
            if reassertAppKitFocus && shouldFocusTerminalSurface {
                terminalPanel.focus()
            }
            return
        }

        if let browserPanel = panel as? BrowserPanel {
            guard shouldFocusBrowserWebView(for: focusIntent) else { return }
            browserPanel.focus()
            return
        }

        if reassertAppKitFocus {
            panel.focus()
        }
    }

    private func activationWindow(for panel: any Panel) -> NSWindow? {
        if let terminalPanel = panel as? TerminalPanel {
            return terminalPanel.surface.uiWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        }
        if let browserPanel = panel as? BrowserPanel {
            return browserPanel.webView.window ?? browserPanel.portalAnchorView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        }
        return NSApp.keyWindow ?? NSApp.mainWindow
    }

    private func yieldForeignOwnedFocusIfNeeded(
        in window: NSWindow,
        targetPanelId: UUID,
        targetIntent: PanelFocusIntent
    ) {
        guard let firstResponder = window.firstResponder else { return }

        for (panelId, panel) in panels where panelId != targetPanelId {
            guard let ownedIntent = panel.ownedFocusIntent(for: firstResponder, in: window) else { continue }
#if DEBUG
            cmuxDebugLog(
                "focus.handoff.begin workspace=\(id.uuidString.prefix(5)) " +
                "fromPanel=\(panelId.uuidString.prefix(5)) toPanel=\(targetPanelId.uuidString.prefix(5)) " +
                "fromIntent=\(String(describing: ownedIntent)) toIntent=\(String(describing: targetIntent))"
            )
#endif
            _ = panel.yieldFocusIntent(ownedIntent, in: window)
            return
        }
    }

    private func shouldMoveTerminalSurfaceFocus(for intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .terminal(.findField), .terminal(.textBoxInput):
            return false
        default:
            return true
        }
    }

    private func shouldFocusBrowserWebView(for intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .browser(.addressBar), .browser(.findField):
            return false
        default:
            return true
        }
    }

    private func shouldAllowBrowserOmnibarAutofocus(for intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .browser(.webView), .panel:
            return true
        default:
            return false
        }
    }

    private func shouldRestoreFocusIntentAfterActivation(_ intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .browser(.addressBar), .browser(.findField), .terminal(.findField), .terminal(.textBoxInput):
            return true
        case .panel, .browser(.webView), .terminal(.surface), .filePreview, .project:
            return false
        }
    }

    // Thin forwards into `SurfaceRegistryModel`, which owns the non-focusing-
    // split focus-reassert state machine (the generation counter and the
    // pending request). The deferred-turn scheduling and AppKit focus
    // reassertion stay app-side in `preserveFocusAfterNonFocusSplit` /
    // `reassertFocusAfterNonFocusSplit`.
    private func beginNonFocusSplitFocusReassert(
        preferredPanelId: UUID,
        splitPanelId: UUID
    ) -> UInt64 {
        surfaceRegistry.beginNonFocusSplitFocusReassert(
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        )
    }

    private func matchesPendingNonFocusSplitFocusReassert(
        generation: UInt64,
        preferredPanelId: UUID,
        splitPanelId: UUID
    ) -> Bool {
        surfaceRegistry.matchesPendingNonFocusSplitFocusReassert(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        )
    }

    private func clearNonFocusSplitFocusReassert(generation: UInt64? = nil) {
        surfaceRegistry.clearNonFocusSplitFocusReassert(generation: generation)
    }

    private func shouldTreatCurrentEventAsExplicitFocusIntent() -> Bool {
        guard let eventType = NSApp.currentEvent?.type else { return false }
        switch eventType {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .keyDown, .keyUp, .scrollWheel,
             .gesture, .magnify, .rotate, .swipe:
            return true
        default:
            return false
        }
    }

    private func markExplicitFocusIntent(on panelId: UUID) {
        surfaceRegistry.markExplicitFocusIntent(on: panelId)
    }

    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        func recordPostCloseState() {
            splitLifecycle.recordPostCloseState(controller: controller, closing: tab, inPane: pane)
        }

        let tabCloseButtonClose = surfaceRegistry.consumeTabCloseButtonClose(tab.id)
        let explicitUserClose = surfaceRegistry.consumeExplicitUserClose(tab.id) || tabCloseButtonClose

        // Remote tmux mirror: closing a window tab means "kill that tmux window".
        // Route ANY non-programmatic close (close button, ⌘W, and batch closes
        // like "close others / close to the left/right") to the remote and veto
        // the immediate local close — the tab is removed when tmux reports
        // %window-close, which also tears the window mirror down (so a batch
        // close can't abandon the mirror's pane surfaces, and the window doesn't
        // reappear on the next rebuild). Programmatic closes (forceCloseTabIds,
        // used by the mirror's own rebuild) are excluded — they do the actual
        // removal. Falls through to the normal local close when there is no live
        // mirror connection.
        //
        // Kill-window is destructive (unlike detach), so it gets the same close
        // confirmation as a local tab with a running process. The decision uses a
        // LIVE activity query (tmux evaluates pane_current_command at query time)
        // rather than the subscription cache, which tmux only refreshes about
        // once a second — otherwise a command started right before ⌘W would
        // slip through unconfirmed. The kill is only sent on Confirm (or when
        // the fresh answer says idle); the %window-close round trip still does
        // the actual tab removal, so the silent-close case costs one extra
        // round trip on a path that already waits one. Batch closes never reach
        // this confirmation: they confirm once up front and route the kill
        // directly (see closeTabsFromContextMenu), bypassing this delegate.
        if isRemoteTmuxMirror, !forceCloseTabIds.contains(tab.id),
           let panelId = panelIdFromSurfaceId(tab.id),
           let remoteTmuxController = hostEnvironment?.remoteTmuxController,
           remoteTmuxController.cachedMirrorTabActivity(workspaceId: id, panelId: panelId) != nil {
            let confirmationSource: CloseTabCloseSource =
                tabCloseButtonClose ? .tabCloseButton : .shortcut
            if !CloseTabWarningStore(defaults: .standard).shouldConfirmClose(
                requiresConfirmation: true, source: confirmationSource
            ) {
                // Close warnings disabled → even an active command wouldn't
                // confirm; kill with no added round trip. Veto unconditionally:
                // the target resolved two lines up on the same main-actor tick,
                // and falling through to a LOCAL close of a mirror tab would
                // leave the remote window alive to resurrect it.
                _ = remoteTmuxController.handleMirrorTabCloseRequested(workspaceId: id, panelId: panelId)
                return false
            } else {
                if pendingCloseConfirmTabIds.contains(tab.id) {
                    return false
                }
                let confirmationManager = owningTabManager
                    ?? hostEnvironment?.tabManagerFor(tabId: id)
                    ?? hostEnvironment?.tabManager
                if let confirmationManager, confirmationManager.workspaceClosing.isCloseConfirmationInFlight {
                    return false
                }
                pendingCloseConfirmTabIds.insert(tab.id)
                let tabId = tab.id

                // Begins the confirmation session and runs the dialog → kill-window
                // flow; shared by the always-warn path (no query) and the queried
                // active-command path. `commandName` (the live foreground command)
                // names the dialog so it can't lag the tab's own rename. Balances
                // pendingCloseConfirmTabIds on every exit.
                let presentConfirmation: @MainActor (String?) -> Void = { [weak self] commandName in
                    guard let self else { return }
                    if let confirmationManager, !confirmationManager.workspaceClosing.beginCloseConfirmationSession() {
                        self.pendingCloseConfirmTabIds.remove(tabId)
                        return
                    }
                    Task { @MainActor in
                        defer {
                            self.pendingCloseConfirmTabIds.remove(tabId)
                            confirmationManager?.workspaceClosing.endCloseConfirmationSession()
                        }

                        // If the tab disappeared while we were scheduling (e.g. the
                        // command finished and another client killed the window), do nothing.
                        guard self.panelIdFromSurfaceId(tabId) != nil else { return }

                        let confirmed = await self.confirmClosePanel(for: tabId, nameOverride: commandName)
                        guard confirmed else { return }

                        // Re-resolves the target, so a window that died while the
                        // dialog was up is a no-op rather than a stray kill.
                        _ = remoteTmuxController.handleMirrorTabCloseRequested(
                            workspaceId: self.id, panelId: panelId
                        )
                    }
                }

                // "Always warn on the tab ✕" makes the dialog unconditional — a
                // live query couldn't change WHETHER we confirm, but it still
                // supplies the fresh command name, so use the cached classification
                // for the name (no round trip) and present immediately.
                if CloseTabWarningStore(defaults: .standard).shouldConfirmClose(
                    requiresConfirmation: false, source: confirmationSource
                ) {
                    let cached = remoteTmuxController.cachedMirrorTabActivity(workspaceId: id, panelId: panelId)
                    presentConfirmation(cached?.activeCommandName)
                    return false
                }

                remoteTmuxController.queryMirrorTabActivity(
                    workspaceId: id, panelId: panelId
                ) { [weak self] activity in
                    guard let self else { return }
                    // Tab vanished while the query was in flight (e.g. the window
                    // died remotely) — nothing left to close.
                    guard self.panelIdFromSurfaceId(tabId) != nil else {
                        self.pendingCloseConfirmTabIds.remove(tabId)
                        return
                    }
                    guard activity.hasActiveCommand else {
                        self.pendingCloseConfirmTabIds.remove(tabId)
                        _ = remoteTmuxController.handleMirrorTabCloseRequested(
                            workspaceId: self.id, panelId: panelId
                        )
                        return
                    }
                    presentConfirmation(activity.activeCommandName)
                }
                return false
            }
        }

        if forceCloseTabIds.contains(tab.id) {
            if !pushClosedPanelHistoryIfEligible(for: tab, inPane: pane) {
                stageClosedBrowserRestoreSnapshotIfNeeded(for: tab, inPane: pane)
            } else {
                clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            }
            recordPostCloseState()
            return true
        }

        let closeConfirmationManager = owningTabManager
            ?? hostEnvironment?.tabManagerFor(tabId: id)
            ?? hostEnvironment?.tabManager
        if let closeConfirmationManager, closeConfirmationManager.workspaceClosing.isCloseConfirmationInFlight {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            if pendingCloseConfirmTabIds.contains(tab.id) {
                return false
            }
            clearCloseHistoryEligibility(tabId: tab.id)
            return false
        }

        if let panelId = panelIdFromSurfaceId(tab.id),
           pinnedPanelIds.contains(panelId) {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            clearCloseHistoryEligibility(tabId: tab.id, panelId: panelId)
            NSSound.beep()
            return false
        }

        if explicitUserClose && shouldCloseWorkspaceOnLastSurface(for: tab.id) {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            clearCloseHistoryEligibility(tabId: tab.id)
            if tabCloseButtonClose {
                owningTabManager?.closeWorkspaceFromTabCloseButton(self)
            } else {
                owningTabManager?.closeWorkspaceFromCloseTabGesture(self)
            }
            return false
        }

        // Check if the panel needs close confirmation
        guard let panelId = panelIdFromSurfaceId(tab.id) else {
            stageClosedBrowserRestoreSnapshotIfNeeded(for: tab, inPane: pane)
            recordPostCloseState()
            return true
        }

        // If confirmation is required, Bonsplit will call into this delegate and we must return false.
        // Show an app-level confirmation, then re-attempt the close with forceCloseTabIds to bypass
        // this gating on the second pass.
        let confirmationSource: CloseTabCloseSource = tabCloseButtonClose ? .tabCloseButton : .shortcut
        if CloseTabWarningStore(defaults: .standard).shouldConfirmClose(
            requiresConfirmation: panelNeedsConfirmClose(panelId: panelId),
            source: confirmationSource
        ) {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            if pendingCloseConfirmTabIds.contains(tab.id) {
                return false
            }

            let confirmationManager = owningTabManager ?? hostEnvironment?.tabManagerFor(tabId: id) ?? hostEnvironment?.tabManager
            if let confirmationManager, !confirmationManager.workspaceClosing.beginCloseConfirmationSession() {
                return false
            }

            pendingCloseConfirmTabIds.insert(tab.id)
            let tabId = tab.id
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    confirmationManager?.workspaceClosing.endCloseConfirmationSession()
                    return
                }
                Task { @MainActor in
                    defer {
                        self.pendingCloseConfirmTabIds.remove(tabId)
                        confirmationManager?.workspaceClosing.endCloseConfirmationSession()
                    }

                    // If the tab disappeared while we were scheduling, do nothing.
                    guard self.panelIdFromSurfaceId(tabId) != nil else { return }

                    let confirmed = await self.confirmClosePanel(for: tabId)
                    guard confirmed else {
                        self.clearCloseHistoryEligibility(tabId: tabId)
                        return
                    }

                    self.forceCloseTabIds.insert(tabId)
                    self.bonsplitController.closeTab(tabId)
                }
            }

            return false
        }

        if !pushClosedPanelHistoryIfEligible(for: tab, inPane: pane) {
            stageClosedBrowserRestoreSnapshotIfNeeded(for: tab, inPane: pane)
        } else {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
        }
        recordPostCloseState()
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didCloseTab tabId: TabID, fromPane pane: PaneID) {
        forceCloseTabIds.remove(tabId)
        surfaceRegistry.removeTabCloseButtonClose(tabId)
        let selectTabId = splitLifecycle.consumePostCloseSelectTabId(forClosed: tabId)
        let shouldClearSplitZoom = splitLifecycle.consumeShouldClearSplitZoom(forClosed: tabId)
        let closedBrowserRestoreSnapshot = closedBrowserRestoreStaging.consumeSnapshot(forTabId: tabId)
        let isDetaching = splitLayout.consumeDetachingMark(tabId)
        if shouldClearSplitZoom {
            clearSplitZoom()
        }

        // Clean up our panel
        guard let panelId = panelIdFromSurfaceId(tabId) else {
            #if DEBUG
            NSLog("[Workspace] didCloseTab: no panelId for tabId")
            #endif
            scheduleTerminalGeometryReconcile()
            if !isDetaching {
                scheduleFocusReconcile()
            }
            return
        }

        #if DEBUG
        NSLog("[Workspace] didCloseTab panelId=\(panelId) remainingPanels=\(panels.count - 1) remainingPanes=\(controller.allPaneIds.count)")
        #endif

        let panel = panels[panelId]
        _ = consumeCloseHistoryEligibility(tabId: tabId, panelId: panelId)
        let transferredRemoteCleanupConfiguration = transferredRemoteCleanupConfigurationsByPanelId[panelId]
        let preservesSurfaceForDetach = isDetaching && panel != nil

        if isDetaching, let panel {
            let browserPanel = panel as? BrowserPanel
            let cachedTitle = panelTitles[panelId]
            let transferFallbackTitle = cachedTitle ?? panel.displayTitle
            let restorableAgent = restoredAgentSnapshotsByPanelId[panelId]
            let restorableAgentResumeState = restoredAgentResumeStatesByPanelId[panelId]
            let resumeBinding = effectiveSurfaceResumeBinding(
                panelId: panelId,
                surfaceResumeBindingIndex: nil
            )
            let agentRuntime = agentRuntimeState(forPanelId: panelId)
            splitLayout.storeDetachedTransfer(DetachedSurfaceTransfer(
                sourceWorkspaceId: id,
                panelId: panelId,
                panel: panel,
                title: resolvedPanelTitle(panelId: panelId, fallback: transferFallbackTitle),
                icon: panel.displayIcon,
                iconImageData: browserPanel?.faviconPNGData,
                kind: panel.panelType.surfaceKind.rawValue,
                isLoading: browserPanel?.isLoading ?? false,
                isPinned: pinnedPanelIds.contains(panelId),
                directory: panelDirectories[panelId],
                ttyName: surfaceTTYNames[panelId],
                cachedTitle: cachedTitle,
                customTitle: panelCustomTitles[panelId],
                customTitleSource: panelCustomTitles[panelId] != nil
                    ? (panelCustomTitleSources[panelId] ?? .user)
                    : nil,
                manuallyUnread: manualUnreadPanelIds.contains(panelId),
                restoredUnreadIndicator: restoredUnreadPanelIndicators[panelId],
                restorableAgent: restorableAgent,
                restorableAgentResumeState: restorableAgentResumeState,
                resumeBinding: resumeBinding,
                agentRuntime: agentRuntime,
                isRemoteTerminal: activeRemoteTerminalSurfaceIds.contains(panelId),
                remoteRelayPort: activeRemoteTerminalSurfaceIds.contains(panelId)
                    ? remoteConfiguration?.relayPort
                    : nil,
                remotePTYSessionID: remotePTYSessionIDForSnapshot(panelId: panelId),
                remoteCleanupConfiguration: transferredRemoteCleanupConfiguration
            ), for: tabId)
        } else {
            if let closedBrowserRestoreSnapshot {
                onClosedBrowserPanel?(closedBrowserRestoreSnapshot)
            }
        }

        let closedRemoteCleanupConfiguration = discardClosedPanelLifecycleState(
            panelId: panelId,
            tabId: tabId,
            paneId: pane,
            panel: panel,
            origin: "tab_close",
            closePanel: !isDetaching,
            publishSurfaceClosedEvent: !isDetaching,
            clearSurfaceNotifications: !preservesSurfaceForDetach,
            requestTransferredRemoteCleanup: false,
            cleanupControllerSurfaceState: !isDetaching
        )
        if !isDetaching {
            owningTabManager?.invalidateFocusHistoryTarget(workspaceId: id, panelId: panelId)
        }
        syncRemotePortScanTTYs()
        recomputeListeningPorts()
        clearRemoteConfigurationIfWorkspaceBecameLocal()
        if !isDetaching, let cleanupConfiguration = closedRemoteCleanupConfiguration {
            Self.requestSSHControlMasterCleanupIfNeeded(configuration: cleanupConfiguration)
        }

        // Keep the workspace invariant for normal close paths.
        // Detach/move flows intentionally allow a temporary empty workspace so AppDelegate can
        // prune the source workspace/window after the tab is attached elsewhere.
        if panels.isEmpty {
            if isDetaching {
                // Detach path also doesn't create a replacement panel this turn, so any
                // pending disconnect placeholder state would survive and leak into a later close.
                pendingRemoteDisconnectReplacement = nil
                scheduleTerminalGeometryReconcile()
                return
            }

            #if DEBUG
            dlog("replacement.remoteDisconnect.fire target=\(pendingRemoteDisconnectReplacement?.target ?? "nil")")
            #endif
            let replacement = createReplacementTerminalPanel()
            if let replacementTabId = surfaceIdFromPanelId(replacement.id),
               let replacementPane = bonsplitController.allPaneIds.first {
                bonsplitController.focusPane(replacementPane)
                bonsplitController.selectTab(replacementTabId)
                applyTabSelection(tabId: replacementTabId, inPane: replacementPane)
            }
            scheduleTerminalGeometryReconcile()
            scheduleFocusReconcile()
            return
        }

        // A remote terminal exited but sibling panels are still alive, so we won't spawn a
        // replacement right now. Drop the placeholder — without this, a later unrelated
        // close could inherit stale remote-disconnect state.
        pendingRemoteDisconnectReplacement = nil

        if let selectTabId,
           bonsplitController.allPaneIds.contains(pane),
           bonsplitController.tabs(inPane: pane).contains(where: { $0.id == selectTabId }),
           bonsplitController.focusedPaneId == pane {
            // Keep selection/focus convergence in the same close transaction to avoid a transient
            // frame where the pane has no selected content.
            bonsplitController.selectTab(selectTabId)
            applyTabSelection(tabId: selectTabId, inPane: pane)
        } else if let focusedPane = bonsplitController.focusedPaneId,
                  let focusedTabId = bonsplitController.selectedTab(inPane: focusedPane)?.id {
            // When closing the last tab in a pane, Bonsplit may focus a different pane and skip
            // emitting didSelectTab. Re-apply the focused selection so sidebar state stays in sync.
            applyTabSelection(tabId: focusedTabId, inPane: focusedPane)
        }

        if bonsplitController.allPaneIds.contains(pane) {
            normalizePinnedTabs(in: pane)
        }
        scheduleTerminalGeometryReconcile()
        if !isDetaching {
            scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didSelectTab tab: Bonsplit.Tab, inPane pane: PaneID) {
        // Suppress the per-move selection churn of a reactive mirror-tab reorder
        // (the user's selection/focus is restored explicitly afterwards).
        guard !isApplyingRemoteTmuxTabReorder else { return }
        applyTabSelection(tabId: tab.id, inPane: pane)
    }

    func splitTabBar(_ controller: BonsplitController, shouldSplitPane pane: PaneID, orientation: SplitOrientation) -> Bool {
        // In a remote tmux mirror, a split (button or any bonsplit-level split)
        // becomes a tmux `split-window`; the new pane arrives via %layout-change.
        // Local workspaces split normally. ALWAYS veto the local split in a
        // mirror — even when the route can't be taken (tab lookup failed, or
        // the connection is reconnecting and can't deliver the command) — a
        // local pane would be an orphan the mirror's rebuild() never
        // reconciles, breaking the 1:1 invariant.
        guard isRemoteTmuxMirror else { return true }
        if let tabId = bonsplitController.selectedTab(inPane: pane)?.id,
           let panelId = panelIdFromSurfaceId(tabId) {
            _ = hostEnvironment?.remoteTmuxController.handleMirrorTabSplitRequested(
                workspaceId: id, panelId: panelId, vertical: orientation == .vertical
            )
        }
        return false
    }

    func splitTabBar(_ controller: BonsplitController, didReorderTabsInPane pane: PaneID, orderedTabIds: [TabID]) {
        // A remote tmux mirror tab reorder propagates to tmux window order.
        guard isRemoteTmuxMirror else { return }
        let orderedPanelIds = orderedTabIds.compactMap { panelIdFromSurfaceId($0) }
        guard !orderedPanelIds.isEmpty else { return }
        hostEnvironment?.remoteTmuxController.handleMirrorWindowsReordered(
            workspaceId: id, orderedPanelIds: orderedPanelIds
        )
    }

    func splitTabBar(_ controller: BonsplitController, didMoveTab tab: Bonsplit.Tab, fromPane source: PaneID, toPane destination: PaneID) {
#if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        let sincePrev: String
        if debugLastDidMoveTabTimestamp > 0 {
            sincePrev = String(format: "%.2f", (now - debugLastDidMoveTabTimestamp) * 1000)
        } else {
            sincePrev = "first"
        }
        debugLastDidMoveTabTimestamp = now
        debugDidMoveTabEventCount += 1
        let movedPanelId = panelIdFromSurfaceId(tab.id)
        let movedPanel = movedPanelId?.uuidString.prefix(5) ?? "unknown"
        let selectedBefore = controller.selectedTab(inPane: destination)
            .map { String(String(describing: $0.id).prefix(5)) } ?? "nil"
        let focusedPaneBefore = controller.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let focusedPanelBefore = focusedPanelId?.uuidString.prefix(5) ?? "nil"
        cmuxDebugLog(
            "split.moveTab idx=\(debugDidMoveTabEventCount) dtSincePrevMs=\(sincePrev) panel=\(movedPanel) " +
            "from=\(source.id.uuidString.prefix(5)) to=\(destination.id.uuidString.prefix(5)) " +
            "sourceTabs=\(controller.tabs(inPane: source).count) destTabs=\(controller.tabs(inPane: destination).count)"
        )
        cmuxDebugLog(
            "split.moveTab.state.before idx=\(debugDidMoveTabEventCount) panel=\(movedPanel) " +
            "destSelected=\(selectedBefore) focusedPane=\(focusedPaneBefore) focusedPanel=\(focusedPanelBefore)"
        )
#endif
        applyTabSelection(tabId: tab.id, inPane: destination)
#if DEBUG
        let movedPanelIdAfter = panelIdFromSurfaceId(tab.id)
#endif
        if let movedPanelId = panelIdFromSurfaceId(tab.id) {
            scheduleMovedTerminalRefresh(panelId: movedPanelId)
        }
#if DEBUG
        let selectedAfter = controller.selectedTab(inPane: destination)
            .map { String(String(describing: $0.id).prefix(5)) } ?? "nil"
        let focusedPaneAfter = controller.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let focusedPanelAfter = focusedPanelId?.uuidString.prefix(5) ?? "nil"
        let movedPanelFocused = (movedPanelIdAfter != nil && movedPanelIdAfter == focusedPanelId) ? 1 : 0
        cmuxDebugLog(
            "split.moveTab.state.after idx=\(debugDidMoveTabEventCount) panel=\(movedPanel) " +
            "destSelected=\(selectedAfter) focusedPane=\(focusedPaneAfter) focusedPanel=\(focusedPanelAfter) " +
            "movedFocused=\(movedPanelFocused)"
        )
#endif
        normalizePinnedTabs(in: source)
        normalizePinnedTabs(in: destination)
        scheduleTerminalGeometryReconcile()
        if !isDetachingCloseTransaction {
            scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
        // See `isApplyingRemoteTmuxTabReorder`: a reactive reorder restores the
        // prior pane focus itself, without re-running tab activation.
        guard !isApplyingRemoteTmuxTabReorder else { return }
        // When a pane is focused, focus its selected tab's panel
        guard let tab = controller.selectedTab(inPane: pane) else { return }
#if DEBUG
        hostEnvironment?.focusLog.append(
            "Workspace.didFocusPane paneId=\(pane.id.uuidString) tabId=\(tab.id) focusedPane=\(controller.focusedPaneId?.id.uuidString ?? "nil")"
        )
#endif
        applyTabSelection(tabId: tab.id, inPane: pane)

        // Apply window background for terminal
        if let panelId = panelIdFromSurfaceId(tab.id),
           let terminalPanel = panels[panelId] as? TerminalPanel {
            terminalPanel.applyWindowBackgroundIfActive()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didClosePane paneId: PaneID) {
        let closedPanelIds = splitLifecycle.consumePaneClosePanelIds(forClosed: paneId.id)
        let closedHistoryEntries = pendingPaneCloseHistoryEntries.removeValue(forKey: paneId.id) ?? []
        let shouldScheduleFocusReconcile = !isDetachingCloseTransaction

        publishCmuxPaneClosed(paneId, closedPanelIds: closedPanelIds, origin: "pane_close")
        if !closedPanelIds.isEmpty {
            if !isDetachingCloseTransaction && !suppressClosedPanelHistory {
                for entry in closedHistoryEntries {
                    ClosedItemHistoryStore.shared.push(.panel(entry))
                }
            }

            for panelId in closedPanelIds {
                let panel = panels[panelId]
                discardClosedPanelLifecycleState(
                    panelId: panelId,
                    tabId: surfaceIdFromPanelId(panelId),
                    paneId: paneId,
                    panel: panel,
                    origin: "pane_close",
                    closePanel: true,
                    publishSurfaceClosedEvent: true,
                    clearSurfaceNotifications: true,
                    requestTransferredRemoteCleanup: true,
                    cleanupControllerSurfaceState: !isDetachingCloseTransaction
                )
                if !isDetachingCloseTransaction {
                    owningTabManager?.invalidateFocusHistoryTarget(workspaceId: id, panelId: panelId)
                }
            }

            syncRemotePortScanTTYs()
            recomputeListeningPorts()
            clearRemoteConfigurationIfWorkspaceBecameLocal()

            if let focusedPane = bonsplitController.focusedPaneId,
               let focusedTabId = bonsplitController.selectedTab(inPane: focusedPane)?.id {
                applyTabSelection(tabId: focusedTabId, inPane: focusedPane)
            } else if shouldScheduleFocusReconcile {
                scheduleFocusReconcile()
            }
        }

        scheduleTerminalGeometryReconcile()
        if shouldScheduleFocusReconcile {
            scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, shouldClosePane pane: PaneID) -> Bool {
        // Check if any panel in this pane needs close confirmation
        let tabs = controller.tabs(inPane: pane)
        for tab in tabs {
            if forceCloseTabIds.contains(tab.id) { continue }
            if let panelId = panelIdFromSurfaceId(tab.id),
               CloseTabWarningStore(defaults: .standard).shouldConfirmClose(
                   requiresConfirmation: panelNeedsConfirmClose(panelId: panelId),
                   source: .shortcut
               ) {
                splitLifecycle.clearPaneClosePanelIds(forPane: pane.id)
                pendingPaneCloseHistoryEntries.removeValue(forKey: pane.id)
                return false
            }
        }
        let panelIds = tabs.compactMap { panelIdFromSurfaceId($0.id) }
        splitLifecycle.recordPaneClosePanelIds(panelIds, forPane: pane.id)
        if suppressClosedPanelHistory || isDetachingCloseTransaction {
            pendingPaneCloseHistoryEntries.removeValue(forKey: pane.id)
        } else {
            let historyEntries = tabs.compactMap { tab -> ClosedPanelHistoryEntry? in
                guard let panelId = panelIdFromSurfaceId(tab.id) else { return nil }
                return closedPanelHistoryEntry(panelId: panelId, tabId: tab.id, pane: pane)
            }
            if historyEntries.isEmpty {
                pendingPaneCloseHistoryEntries.removeValue(forKey: pane.id)
            } else {
                pendingPaneCloseHistoryEntries[pane.id] = historyEntries
            }
        }
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation) {
#if DEBUG
        let panelKindForTab: (TabID) -> String = { tabId in
            guard let panelId = self.panelIdFromSurfaceId(tabId),
                  let panel = self.panels[panelId] else { return "placeholder" }
            if panel is TerminalPanel { return "terminal" }
            if panel is BrowserPanel { return "browser" }
            return String(describing: type(of: panel))
        }
        let paneKindSummary: (PaneID) -> String = { paneId in
            let tabs = controller.tabs(inPane: paneId)
            guard !tabs.isEmpty else { return "-" }
            return tabs.map { tab in
                String(panelKindForTab(tab.id).prefix(1))
            }.joined(separator: ",")
        }
        let originalSelectedKind = controller.selectedTab(inPane: originalPane).map { panelKindForTab($0.id) } ?? "none"
        let newSelectedKind = controller.selectedTab(inPane: newPane).map { panelKindForTab($0.id) } ?? "none"
        cmuxDebugLog(
            "split.didSplit original=\(originalPane.id.uuidString.prefix(5)) new=\(newPane.id.uuidString.prefix(5)) " +
            "orientation=\(orientation) programmatic=\(isProgrammaticSplit ? 1 : 0) " +
            "originalTabs=\(controller.tabs(inPane: originalPane).count) newTabs=\(controller.tabs(inPane: newPane).count) " +
            "originalSelected=\(originalSelectedKind) newSelected=\(newSelectedKind) " +
            "originalKinds=[\(paneKindSummary(originalPane))] newKinds=[\(paneKindSummary(newPane))]"
        )
#endif
        let rearmBrowserPortalHostReplacement: (PaneID, String) -> Void = { paneId, reason in
            for tab in controller.tabs(inPane: paneId) {
                guard let panelId = self.panelIdFromSurfaceId(tab.id),
                      let browserPanel = self.browserPanel(for: panelId) else {
                    continue
                }
                browserPanel.preparePortalHostReplacementForNextDistinctClaim(
                    inPane: paneId,
                    reason: reason
                )
            }
        }
        rearmBrowserPortalHostReplacement(originalPane, "workspace.didSplit.original")
        rearmBrowserPortalHostReplacement(newPane, "workspace.didSplit.new")

        // Only auto-create a terminal if the split came from bonsplit UI.
        // Programmatic splits via newTerminalSplit() set isProgrammaticSplit and handle their own panels.
        guard !isProgrammaticSplit else {
            normalizePinnedTabs(in: originalPane)
            normalizePinnedTabs(in: newPane)
            scheduleTerminalGeometryReconcile()
            return
        }

        // If the new pane already has a tab, this split moved an existing tab (drag-to-split).
        //
        // In the "drag the only tab to split edge" case, bonsplit inserts a placeholder "Empty"
        // tab in the source pane to avoid leaving it tabless. In cmux, this is undesirable:
        // it creates a pane with no real surfaces and leaves an "Empty" tab in the tab bar.
        //
        // Replace placeholder-only source panes with a real terminal surface, then drop the
        // placeholder tabs so the UI stays consistent and pane lists don't contain empties.
        if !controller.tabs(inPane: newPane).isEmpty {
            let originalTabs = controller.tabs(inPane: originalPane)
            let hasRealSurface = originalTabs.contains { panelIdFromSurfaceId($0.id) != nil }
#if DEBUG
            cmuxDebugLog(
                "split.didSplit.drag original=\(originalPane.id.uuidString.prefix(5)) " +
                "new=\(newPane.id.uuidString.prefix(5)) originalTabs=\(originalTabs.count) " +
                "newTabs=\(controller.tabs(inPane: newPane).count) hasRealSurface=\(hasRealSurface ? 1 : 0) " +
                "originalKinds=[\(paneKindSummary(originalPane))] newKinds=[\(paneKindSummary(newPane))]"
            )
#endif
            if !hasRealSurface {
                let placeholderTabs = originalTabs.filter { panelIdFromSurfaceId($0.id) == nil }
#if DEBUG
                cmuxDebugLog(
                    "split.placeholderRepair pane=\(originalPane.id.uuidString.prefix(5)) " +
                    "action=reusePlaceholder placeholderCount=\(placeholderTabs.count)"
                )
#endif
                if let replacementTab = placeholderTabs.first {
                    // Keep the existing placeholder tab identity and replace only the panel mapping.
                    // This avoids an extra create+close tab churn that can transiently render an
                    // empty pane during drag-to-split of a single-tab pane.
                    let inheritedConfig = inheritedTerminalConfig(inPane: originalPane)

                    let replacementPanel = TerminalPanel(
                        workspaceId: id,
                        context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                        configTemplate: inheritedConfig,
                        portOrdinal: portOrdinal,
                        additionalEnvironment: startupEnvironmentMergingWorkspaceEnvironment([:])
                    )
                    configureNewTerminalPanel(replacementPanel)
                    panels[replacementPanel.id] = replacementPanel
                    panelTitles[replacementPanel.id] = replacementPanel.displayTitle
                    seedTerminalInheritanceFontPoints(panelId: replacementPanel.id, configTemplate: inheritedConfig)
                    surfaceIdToPanelId[replacementTab.id] = replacementPanel.id

                    bonsplitController.updateTab(
                        replacementTab.id,
                        title: replacementPanel.displayTitle,
                        icon: .some(replacementPanel.displayIcon),
                        iconImageData: .some(nil),
                        kind: .some(SurfaceKind.terminal.rawValue),
                        hasCustomTitle: false,
                        isDirty: replacementPanel.isDirty,
                        showsNotificationBadge: false,
                        isLoading: false,
                        isPinned: false
                    )
                    publishCmuxSurfaceCreated(replacementPanel.id, paneId: originalPane, kind: "terminal", origin: "placeholder_repair", focused: false)

                    for extraPlaceholder in placeholderTabs.dropFirst() {
                        bonsplitController.closeTab(extraPlaceholder.id)
                    }
                } else {
#if DEBUG
                    cmuxDebugLog(
                        "split.placeholderRepair pane=\(originalPane.id.uuidString.prefix(5)) " +
                        "fallback=createTerminalAndDropPlaceholders"
                    )
#endif
                    _ = newTerminalSurface(inPane: originalPane, focus: false)
                    for tab in controller.tabs(inPane: originalPane) {
                        if panelIdFromSurfaceId(tab.id) == nil {
                            bonsplitController.closeTab(tab.id)
                        }
                    }
                }
            }
            normalizePinnedTabs(in: originalPane)
            normalizePinnedTabs(in: newPane)
            scheduleTerminalGeometryReconcile()
            return
        }

        // Mirror Cmd+D behavior: split buttons should always seed a terminal in the new pane.
        // When the focused source is a browser, inherit terminal config from nearby terminals
        // (or fall back to defaults) instead of leaving an empty selector pane.
        let sourceTabId = controller.selectedTab(inPane: originalPane)?.id
        let sourcePanelId = sourceTabId.flatMap { panelIdFromSurfaceId($0) }

#if DEBUG
        cmuxDebugLog(
            "split.didSplit.autoCreate pane=\(newPane.id.uuidString.prefix(5)) " +
            "fromPane=\(originalPane.id.uuidString.prefix(5)) sourcePanel=\(sourcePanelId.map { String($0.uuidString.prefix(5)) } ?? "none")"
        )
#endif

        let inheritedConfig = inheritedTerminalConfig(
            preferredPanelId: sourcePanelId,
            inPane: originalPane
        )

        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            portOrdinal: portOrdinal,
            additionalEnvironment: startupEnvironmentMergingWorkspaceEnvironment([:])
        )
        configureNewTerminalPanel(newPanel)
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)

        guard let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal.rawValue,
            isDirty: newPanel.isDirty,
            isPinned: false,
            inPane: newPane
        ) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            terminalInheritanceFontPointsByPanelId.removeValue(forKey: newPanel.id)
            return
        }

        surfaceIdToPanelId[newTabId] = newPanel.id
        normalizePinnedTabs(in: newPane)
        publishCmuxSplitCreated(newPane, sourcePaneId: originalPane, orientation: orientation, surfaceId: newPanel.id, kind: "terminal", origin: "ui_split", focused: true)
#if DEBUG
        cmuxDebugLog(
            "split.didSplit.autoCreate.done pane=\(newPane.id.uuidString.prefix(5)) " +
            "panel=\(newPanel.id.uuidString.prefix(5))"
        )
#endif

        // `createTab` selects the new tab but does not emit didSelectTab; schedule an explicit
        // selection so our focus/unfocus logic runs after this delegate callback returns.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.bonsplitController.focusedPaneId == newPane {
                self.bonsplitController.selectTab(newTabId)
            }
            self.scheduleTerminalGeometryReconcile()
            self.scheduleFocusReconcile()
        }
    }

    private func selectedTerminalPanel(inPane pane: PaneID) -> TerminalPanel? {
        guard let selectedTab = bonsplitController.selectedTab(inPane: pane),
              let panelId = panelIdFromSurfaceId(selectedTab.id) else {
            return nil
        }
        return terminalPanel(for: panelId)
    }

    private func executeSurfaceTabBarCommandButton(identifier: String, inPane pane: PaneID) {
        guard let executable = surfaceTabBarCommandButtons[identifier] else {
            return
        }
        let presentingWindow = selectedTerminalPanel(inPane: pane)?.surface.uiWindow
            ?? NSApp.keyWindow
            ?? NSApp.mainWindow

        if let builtInAction = executable.builtInAction {
            switch builtInAction {
            case .newWorkspace:
                owningTabManager?.addWorkspace()
            case .cloudVM:
                _ = hostEnvironment?.performCloudVMAction(
                    tabManager: owningTabManager,
                    preferredWindow: presentingWindow,
                    debugSource: "surfaceTabBar.cloudVM",
                    onCompletion: nil
                )
            case .newTerminal, .newBrowser, .splitRight, .splitDown:
                break
            }
            return
        }

        guard let globalConfigPath = surfaceTabBarButtonGlobalConfigPath else {
            return
        }

        if let workspaceCommand = executable.workspaceCommand {
            bonsplitController.focusPane(pane)
            if let selectedTab = bonsplitController.selectedTab(inPane: pane) {
                applyTabSelection(tabId: selectedTab.id, inPane: pane)
            }

            let paneDirectory = selectedTerminalPanel(inPane: pane).flatMap { terminal -> String? in
                for candidate in [panelDirectories[terminal.id], terminal.requestedWorkingDirectory] {
                    let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let trimmed, !trimmed.isEmpty {
                        return trimmed
                    }
                }
                return nil
            }
            let rawCwd = paneDirectory ?? currentDirectory
            let trimmedCwd = rawCwd.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseCwd = trimmedCwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : trimmedCwd
            guard let tabManager = owningTabManager else { return }
            _ = CmuxConfigExecutor.execute(
                command: workspaceCommand.command,
                tabManager: tabManager,
                baseCwd: baseCwd,
                configSourcePath: workspaceCommand.sourcePath,
                globalConfigPath: globalConfigPath,
                displayTitle: executable.button.title ?? executable.button.tooltip ?? workspaceCommand.command.name,
                actionID: executable.button.id,
                icon: executable.button.icon ?? executable.button.action.defaultButtonIcon,
                iconSourcePath: executable.button.iconSourcePath,
                presentingWindow: presentingWindow
            )
            return
        }

        guard let command = executable.button.terminalCommand else { return }
        let target = executable.button.resolvedTerminalCommandTarget
        let didExecute = CmuxConfigExecutor.prepareShellInputIfAuthorized(
            command,
            confirm: executable.button.confirm ?? false,
            actionID: executable.button.id,
            target: target,
            configSourcePath: executable.terminalCommandSourcePath ?? surfaceTabBarButtonSourcePath,
            globalConfigPath: globalConfigPath,
            displayTitle: executable.button.title ?? executable.button.tooltip,
            icon: executable.button.icon ?? executable.button.action.defaultButtonIcon,
            iconSourcePath: executable.button.iconSourcePath,
            presentingWindow: presentingWindow
        ) { [weak self] shellInput in
            guard let self else { return }
            self.bonsplitController.focusPane(pane)
            switch target {
            case .currentTerminal:
                self.selectedTerminalPanel(inPane: pane)?.sendInput(shellInput)
            case .newTabInCurrentPane:
                _ = self.newTerminalSurface(
                    inPane: pane,
                    focus: true,
                    initialInput: shellInput,
                    inheritWorkingDirectoryFallback: true
                )
            }
        }
        guard didExecute else {
            return
        }
    }

    func splitTabBar(_ controller: BonsplitController, didRequestNewTab kind: String, inPane pane: PaneID) {
        switch kind {
        case "terminal":
            _ = newTerminalSurface(inPane: pane, inheritWorkingDirectoryFallback: true)
        case "browser":
            _ = newBrowserSurface(inPane: pane)
        default:
            _ = newTerminalSurface(inPane: pane, inheritWorkingDirectoryFallback: true)
        }
    }

    func splitTabBar(_ controller: BonsplitController, didRequestCustomAction identifier: String, inPane pane: PaneID) {
#if DEBUG
        cmuxDebugLog(
            "split.customAction.request workspace=\(id.uuidString.prefix(5)) " +
            "pane=\(pane.id.uuidString.prefix(5)) identifier=\(identifier)"
        )
#endif
        executeSurfaceTabBarCommandButton(identifier: identifier, inPane: pane)
    }

    func splitTabBar(_ controller: BonsplitController, didRequestTabContextAction action: TabContextAction, for tab: Bonsplit.Tab, inPane pane: PaneID) {
        switch action {
        case .rename:
            contextMenuCoordinator.renameTab(tab.id)
        case .clearName:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            setPanelCustomTitle(panelId: panelId, title: nil)
        case .copyIdentifiers:
            contextMenuCoordinator.copyIdentifiers(for: tab.id)
        case .closeToLeft:
            contextMenuCoordinator.closeTabsToLeft(of: tab.id, inPane: pane)
        case .closeToRight:
            contextMenuCoordinator.closeTabsToRight(of: tab.id, inPane: pane)
        case .closeOthers:
            contextMenuCoordinator.closeOtherTabs(than: tab.id, inPane: pane)
        case .move:
            if let destination = contextMenuMoveDestinations(for: tab.id).first {
                _ = contextMenuCoordinator.moveTab(tab.id, toMoveDestination: destination.id)
            }
        case .moveToNewWorkspace:
            _ = hostEnvironment?.moveBonsplitTabToNewWorkspace(
                tabId: tab.id.uuid,
                destinationManager: nil,
                title: nil,
                focus: true,
                focusWindow: false,
                placementOverride: nil,
                insertionIndexOverride: nil
            )
        case .moveToLeftPane:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            _ = moveSurfaceToAdjacentPane(panelId: panelId, direction: .left)
        case .moveToRightPane:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            _ = moveSurfaceToAdjacentPane(panelId: panelId, direction: .right)
        case .newTerminalToRight:
            contextMenuCoordinator.createTerminalToRight(of: tab.id, inPane: pane)
        case .newBrowserToRight:
            contextMenuCoordinator.createBrowserToRight(of: tab.id, inPane: pane)
        case .reload:
            guard let panelId = panelIdFromSurfaceId(tab.id),
                  let browser = browserPanel(for: panelId) else { return }
            browser.reload()
        case .toggleAudioMute:
            guard let panelId = panelIdFromSurfaceId(tab.id),
                  let browser = browserPanel(for: panelId) else { return }
            guard browser.toggleMute() else {
                NSSound.beep()
                return
            }
            syncBrowserAudioMuteStateForPanel(panelId, browserPanel: browser)
        case .duplicate:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            _ = duplicateBrowserToRight(panelId: panelId)
        case .togglePin:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            let shouldPin = !pinnedPanelIds.contains(panelId)
            setPanelPinned(panelId: panelId, pinned: shouldPin)
        case .markAsRead:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            markPanelRead(panelId)
        case .markAsUnread:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            markPanelUnread(panelId)
        case .toggleZoom:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            toggleSplitZoom(panelId: panelId)
        case .forkConversation,
             .forkConversationRight,
             .forkConversationLeft,
             .forkConversationTop,
             .forkConversationBottom,
             .forkConversationNewTab,
             .forkConversationNewWorkspace:
            handleForkConversationContextAction(action, for: tab, inPane: pane)
        @unknown default:
            break
        }
    }

    /// Forwards to ``AgentForkCoordinator/handleForkConversationContextAction(panelId:destination:anchorTabId:paneId:)``.
    /// The panel-id resolution from the tab and the configured-destination
    /// resolution from the action stay app-side (the coordinator never imports
    /// the app-target `TabContextAction` right-click vocabulary directly).
    private func handleForkConversationContextAction(_ action: TabContextAction, for tab: Bonsplit.Tab, inPane pane: PaneID) {
        agentForkCoordinator.handleForkConversationContextAction(
            panelId: panelIdFromSurfaceId(tab.id),
            destination: {
                action == .forkConversation
                    ? AgentConversationForkDestination.configuredDefault()
                    : AgentConversationForkDestination(tabContextAction: action)
            },
            anchorTabId: tab.id,
            paneId: pane
        )
    }

    func splitTabBar(_ controller: BonsplitController, didRequestTabMoveToDestination destinationId: String, for tab: Bonsplit.Tab, inPane pane: PaneID) {
        _ = contextMenuCoordinator.moveTab(tab.id, toMoveDestination: destinationId)
    }

    func splitTabBar(_ controller: BonsplitController, didChangeGeometry snapshot: LayoutSnapshot) {
        tmuxLayoutSnapshot = snapshot
        // Every order/membership mutation (same-pane reorder, cross-pane move,
        // split, close) routes through here. A pure reorder mutates only
        // bonsplit's internal state, which is not `@Published`, so observers
        // would miss it. Bump `paneLayoutVersion` only when the ordered panel-id
        // sequence actually changed, so divider drags and selection-only events
        // (also routed here) do not fire `objectWillChange` app-wide.
        surfaceList.registerGeometryChange()
        scheduleTerminalGeometryReconcile()
        if !isDetachingCloseTransaction {
            scheduleFocusReconcile()
        }
    }

    // No post-close polling refresh loop: we rely on view invariants and Ghostty's wakeups.
}

/// `Workspace` is the live host for its ``RemoteTmuxMirrorCoordinator``. The
/// coordinator (in `CmuxRemoteWorkspace`) owns the pane-close orchestration and
/// reaches back through this witness for the one workspace-side decision it
/// cannot make on its own: resolving the owning tab manager, building the
/// localized dialog copy, and running the kill-pane confirmation modal. The
/// localized strings stay app-side and are passed through the seam only as a
/// classified active-command `String?`. The coordinator is held by `Workspace`
/// and references this host weakly, so there is no retain cycle.
extension Workspace: RemoteTmuxMirrorHosting {
    func presentRemoteTmuxPaneCloseConfirmation(activeCommand: String?) -> Bool {
        // No manager → no way to ask → refuse the destructive kill rather than
        // falling through to an unconfirmed one (only reachable in teardown
        // states where the pane header shouldn't be clickable).
        guard let manager = owningTabManager
            ?? hostEnvironment?.tabManagerFor(tabId: id)
            ?? hostEnvironment?.tabManager else { return false }
        let message: String
        if let activeCommand, !activeCommand.isEmpty {
            message = String(localized: "dialog.closeTab.messageNamed", defaultValue: "This will close \"\(activeCommand)\".")
        } else {
            message = String(localized: "dialog.closeTab.message", defaultValue: "This will close the current tab.")
        }
        return manager.workspaceClosing.confirmClose(
            title: String(localized: "dialog.closeTab.title", defaultValue: "Close tab?"),
            message: message,
            acceptCmdD: false
        )
    }
}
