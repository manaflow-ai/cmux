import CmuxAppKitSupportUI
import CmuxFoundation
import Foundation
import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteSession
import CmuxRemoteWorkspace
import CmuxWorkspaces
import CmuxTerminal
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

#if DEBUG
private func debugWorkspaceDescriptionPreview(_ text: String?, limit: Int = 120) -> String {
    guard let text else { return "nil" }
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    if escaped.count <= limit {
        return escaped
    }
    return "\(escaped.prefix(limit))..."
}
#endif

private final class WorkspacePendingTerminalInputObserver: @unchecked Sendable {
    var observer: NSObjectProtocol?
}

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
        applySessionDividerPositions(snapshotNode: snapshot.layout, liveNode: bonsplitController.treeSnapshot())

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

    private func sessionPanelSnapshot(
        panelId: UUID,
        includeScrollback: Bool,
        restorableAgent: SessionRestorableAgentSnapshot?,
        resumeBinding: SurfaceResumeBindingSnapshot?
    ) -> SessionPanelSnapshot? {
        guard let panel = panels[panelId] else { return nil }

        let compatibleIndexedRestorableAgent = restorableAgent.flatMap {
            Self.restorableAgentForSessionRestore(
                $0,
                resumeBinding: resumeBinding
            )
        }
        if restorableAgent != nil, compatibleIndexedRestorableAgent == nil {
            clearRestoredAgentSnapshot(panelId: panelId)
        }
        if let compatibleRestorableAgent = compatibleIndexedRestorableAgent {
            let fingerprint = TabManager.restorableAgentSnapshotFingerprint(compatibleRestorableAgent)
            if invalidatedRestoredAgentFingerprintsByPanelId[panelId] == fingerprint {
                clearRestoredAgentSnapshot(panelId: panelId)
            } else {
                restoredAgentSnapshotsByPanelId[panelId] = compatibleRestorableAgent
                if restoredAgentResumeStatesByPanelId[panelId] == nil {
                    restoredAgentResumeStatesByPanelId[panelId] = restoredAgentResumeStateForAcceptedSnapshot(
                        panelId: panelId
                    )
                }
                invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
            }
        }
        let hibernationState = (panel as? TerminalPanel)?.agentHibernationState
        let effectiveHibernationState = hibernationState.flatMap { state in
            Self.restorableAgentForSessionRestore(
                state.agent,
                resumeBinding: resumeBinding
            ) == nil ? nil : state
        }
        let effectiveRestorableAgent = Self.restorableAgentForSessionRestore(
            effectiveHibernationState?.agent ?? restoredAgentSnapshotsByPanelId[panelId],
            resumeBinding: resumeBinding
        )

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
        let rightSidebarToolSnapshot: SessionRightSidebarToolPanelSnapshot?; var customSidebarSnapshot: SessionCustomSidebarPanelSnapshot? = nil
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
                autoResumeAgentSessions: AgentSessionAutoResumeSettings.isEnabled(defaults: agentSessionAutoResumeDefaults) && (agentWasRunning ?? true),
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
            let capturedScrollback = includeScrollback && shouldPersistScrollback && effectiveHibernationState == nil
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
                hibernation: effectiveHibernationState.map {
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
        case .customSidebar:
            guard let snapshot = customSidebarSessionSnapshot(for: panel) else { return nil }
            terminalSnapshot = nil; browserSnapshot = nil; markdownSnapshot = nil; filePreviewSnapshot = nil; rightSidebarToolSnapshot = nil
            customSidebarSnapshot = snapshot; agentSessionSnapshot = nil; projectSnapshot = nil
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
            customSidebar: customSidebarSnapshot,
            agentSession: agentSessionSnapshot,
            project: projectSnapshot
        )
    }
    private func closedPanelHistoryEntry(panelId: UUID, tabId: TabID, pane: PaneID) -> ClosedPanelHistoryEntry? {
        guard !suppressClosedPanelHistory else { return nil }
        owningTabManager?.flushPendingPanelTitleUpdatesForWorkspaceSnapshot()
        guard let tabIndex = bonsplitController.tabs(inPane: pane).firstIndex(where: { $0.id == tabId }) else {
            return nil
        }
        let paneTabs = bonsplitController.tabs(inPane: pane)
        let paneAnchorPanelId: UUID? = {
            if tabIndex + 1 < paneTabs.count {
                return panelIdFromSurfaceId(paneTabs[tabIndex + 1].id)
            }
            if tabIndex > 0 {
                return panelIdFromSurfaceId(paneTabs[tabIndex - 1].id)
            }
            return nil
        }()
        let fallbackPlan = browserCloseFallbackPlan(
            forPaneId: pane.id.uuidString,
            in: bonsplitController.treeSnapshot()
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
        let eligibleByTab = closeHistoryEligibleTabIds.remove(tabId) != nil
        let eligibleByPanel = panelId.map { closeHistoryEligiblePanelIds.remove($0) != nil } ?? false
        return eligibleByTab || eligibleByPanel
    }

    private func clearCloseHistoryEligibility(tabId: TabID, panelId: UUID? = nil) {
        closeHistoryEligibleTabIds.remove(tabId)
        let resolvedPanelId = panelId ?? panelIdFromSurfaceId(tabId)
        if let resolvedPanelId {
            closeHistoryEligiblePanelIds.remove(resolvedPanelId)
        }
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
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
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

    nonisolated private static func resumeBindingForSessionRestore(
        _ binding: SurfaceResumeBindingSnapshot?,
        restorableAgent: SessionRestorableAgentSnapshot?
    ) -> SurfaceResumeBindingSnapshot? {
        guard let binding, binding.isAgentHookBinding, let restorableAgent else {
            return binding
        }
        guard binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines) == restorableAgent.sessionId else {
            return binding
        }
        if let bindingKind = binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bindingKind.isEmpty,
           RestorableAgentKind(rawValue: bindingKind) != restorableAgent.kind {
            return binding
        }

        // Restore has no live hook cwd; use the snapshot's derived restorable cwd
        // and fall back to launch capture only for older snapshots.
        let snapshotRestorableWorkingDirectory =
            restorableAgent.workingDirectory ?? restorableAgent.launchCommand?.workingDirectory
        let resolvedWorkingDirectory = AgentResumeWorkingDirectory().resolve(
            kind: binding.kind ?? restorableAgent.kind.rawValue,
            runtimeCwd: binding.cwd,
            launchWorkingDirectory: snapshotRestorableWorkingDirectory
        )
        guard resolvedWorkingDirectory != binding.cwd else {
            return binding
        }
        return binding.retargetingWorkingDirectory(resolvedWorkingDirectory)
    }

    nonisolated private static func restorableAgentForSessionRestore(
        _ restorableAgent: SessionRestorableAgentSnapshot?,
        resumeBinding: SurfaceResumeBindingSnapshot?
    ) -> SessionRestorableAgentSnapshot? {
        guard let restorableAgent else { return nil }
        guard let resumeBinding, resumeBinding.isAgentHookBinding else {
            return restorableAgent
        }

        if let checkpointId = normalizedResumeBindingValue(resumeBinding.checkpointId),
           checkpointId != restorableAgent.sessionId {
            return nil
        }
        if let kindValue = normalizedResumeBindingValue(resumeBinding.kind) {
            guard let bindingKind = RestorableAgentKind(rawValue: kindValue),
                  bindingKind == restorableAgent.kind else {
                return nil
            }
        }
        return restorableAgent
    }

    nonisolated private static func normalizedResumeBindingValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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
            SessionPersistencePolicy.maxScrollbackCharactersPerTerminal
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
        for panelId in panels.keys {
            let storedBinding = surfaceResumeBindingsByPanelId[panelId]
            let detectedBinding = surfaceResumeBindingIndex.binding(workspaceId: id, panelId: panelId)

            guard let storedBinding else {
                if let detectedBinding, detectedBinding.isProcessDetected {
                    surfaceResumeBindingsByPanelId[panelId] = detectedBinding
                }
                continue
            }
            guard let detectedBinding else {
                if storedBinding.isProcessDetected {
                    surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
                }
                continue
            }
            if storedBinding.shouldYieldToDetectedSurfaceResumeBinding(detectedBinding) {
                surfaceResumeBindingsByPanelId[panelId] = detectedBinding
            } else if storedBinding.isProcessDetected {
                surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
            }
        }
    }

    func effectiveSurfaceResumeBinding(
        panelId: UUID,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex?
    ) -> SurfaceResumeBindingSnapshot? {
        let storedBinding = surfaceResumeBindingsByPanelId[panelId]
        guard let surfaceResumeBindingIndex else {
            return storedBinding
        }

        let detectedBinding = surfaceResumeBindingIndex.binding(workspaceId: id, panelId: panelId)
        guard let storedBinding else { return detectedBinding }
        guard let detectedBinding else { return storedBinding.isProcessDetected ? nil : storedBinding }
        if storedBinding.shouldYieldToDetectedSurfaceResumeBinding(detectedBinding) { return detectedBinding }
        if storedBinding.isProcessDetected { return nil }
        return storedBinding
    }

    private func createPanel(
        from snapshot: SessionPanelSnapshot,
        inPane paneId: PaneID,
        snapshotWorkspaceId: UUID?
    ) -> UUID? {
        switch snapshot.type {
        case .terminal:
            let snapshotRestorableAgent = snapshot.terminal?.agent
            let resumeBinding = Self.resumeBindingForSessionRestore(
                snapshot.terminal?.resumeBinding,
                restorableAgent: snapshotRestorableAgent
            )
            let restorableAgent = Self.restorableAgentForSessionRestore(
                snapshotRestorableAgent,
                resumeBinding: resumeBinding
            )
            let restoredHibernation = restorableAgent != nil ? snapshot.terminal?.hibernation : nil
            let autoResumeAgentSessions = AgentSessionAutoResumeSettings.isEnabled(defaults: agentSessionAutoResumeDefaults)
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
            let restoresRemoteWorkspaceTerminalSnapshot = remoteStartupCommand != nil && snapshot.terminal?.isRemoteTerminal != false
            let restoresLocalTerminalInRemoteWorkspace = remoteStartupCommand != nil && snapshot.terminal?.isRemoteTerminal == false
            let restoredBindingLaunch: SurfaceResumeStartupLaunch? = if restoresRemoteWorkspaceTerminalSnapshot {
                effectiveResumeBindingForStartup?.remoteStartupInputWithLauncherScript(allowLauncherScript: false)
                    .map(SurfaceResumeStartupLaunch.input)
            } else if restoresLocalTerminalInRemoteWorkspace {
                effectiveResumeBindingForStartup?.startupInputWithLauncherScript(allowLauncherScript: false)
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
                    if restoresRemoteWorkspaceTerminalSnapshot {
                        restorableAgent?.resumeStartupInput(allowLauncherScript: false, allowOversizedInlineInput: true)
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
            // cmux is itself resuming this agent session onto the restored surface.
            // Some agents (codex) fire NO SessionStart hook on resume, and an
            // `sr codex resume` bypasses the hook-injecting shim entirely, so
            // record the (session, surface) binding from cmux's own authority
            // instead of waiting for a hook that will not arrive; otherwise the
            // chat registry keeps the stale pre-relaunch record (dead pid ->
            // .ended) and the iOS GUI shows it read-only. The actual call is made
            // AFTER the surface is created, keyed on the real `terminalPanel.id`
            // (which differs from `snapshot.id` when a surface-id collision forces
            // a fresh id on restore-into-live / duplicate-workspace). The
            // (session id, agent source) comes from the restorable-agent snapshot
            // when present, else from the agent-hook resume binding (most restores
            // carry only the binding, whose `checkpointId` IS the agent session id).
            let resumeReboundSession: (sessionID: String, source: String)? = {
                if let restorableAgent {
                    return (restorableAgent.sessionId, restorableAgent.kind.rawValue)
                }
                if let binding = resumeBinding,
                   binding.isAgentHookBinding,
                   let checkpoint = binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !checkpoint.isEmpty,
                   let bindingKind = binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !bindingKind.isEmpty {
                    return (checkpoint, bindingKind)
                }
                return nil
            }()
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
            let replayEnvironment = SessionScrollbackReplayStore.replayEnvironment(for: restoredScrollback)
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
            // Re-bind the resumed agent session from cmux's own authority, keyed
            // on the surface that was actually created. `terminalPanel.id` equals
            // `snapshot.id` on the normal path, but on a surface-id collision
            // (restore-into-live / duplicate-workspace) `newTerminalSurface`
            // minted a fresh id, so keying on `snapshot.id` would bind to a
            // surface that does not exist and the GUI would never find the
            // session. This is unconditional on whether cmux runs the resume
            // command itself: a restored surface that CARRIES a resumable agent
            // binding must flip its registry record to live/.idle so the iOS GUI
            // is editable, even when auto-resume is off and the user resumes
            // manually (e.g. `sr codex resume`). Recording .idle here is the safe
            // direction per the spec — never invent `ended`.
            if let resumeReboundSession {
                AgentChatTranscriptService.recordResumeIntent(
                    sessionID: resumeReboundSession.sessionID,
                    source: resumeReboundSession.source,
                    surfaceID: terminalPanel.id.uuidString,
                    workspaceID: id.uuidString,
                    workingDirectory: workingDirectory
                )
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
            // A terminal whose startup command cds itself (agent resume, tmux
            // attach, agent-hook) is spawned without a working directory, so its
            // shell starts in the default directory and shell integration reports
            // that directory (typically home) before the startup command cds into
            // the saved one. Remember the saved directory so the spurious initial
            // report is ignored instead of overwriting the restored workspace cwd
            // (#6617). `shouldIgnoreRestoredGuardedDirectoryReport` decides how long
            // to guard: once while the saved directory still exists, persistently
            // while it is on an unmounted volume, and not at all once it has been
            // deleted (the shell's reported cwd is then the real fallback).
            //
            // Only guard LOCAL terminals. That guard's existence check stats the
            // local Mac, so a remote terminal's remote saved path (e.g.
            // /home/dev/repo) would be misclassified as deleted and its remote
            // home report wrongly honored. Remote restores keep the prior
            // behavior (no guard), which matches the original unmounted-volume
            // guard that was inherently local (/Volumes paths only).
            let restoredDirectoryIsLocalPath =
                !restoresRemoteWorkspaceTerminalSnapshot &&
                restoredRemotePTYSessionID == nil &&
                snapshot.terminal?.isRemoteTerminal != true
            if startupHandlesWorkingDirectory,
               localWorkingDirectory == nil,
               restoredDirectoryIsLocalPath,
               let guardedWorkingDirectory = savedWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
               !guardedWorkingDirectory.isEmpty {
                restoredGuardedWorkingDirectoriesByPanelId[terminalPanel.id] = guardedWorkingDirectory
            } else {
                restoredGuardedWorkingDirectoriesByPanelId.removeValue(forKey: terminalPanel.id)
            }
            let fallbackScrollback = SessionPersistencePolicy.truncatedScrollback(restoredScrollback)
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
        case .customSidebar: return restoreCustomSidebarPanel(from: snapshot, inPane: paneId)
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

    func applySessionPanelMetadata(_ snapshot: SessionPanelSnapshot, toPanelId panelId: UUID) {
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
            updatePanelDirectory(panelId: panelId, directory: directory, source: .restoredSnapshotMetadata)
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
        guard let notificationStore = AppDelegate.shared?.notificationStore else { return }
        if isManuallyUnread {
            notificationStore.markUnread(forTabId: id)
        } else {
            notificationStore.clearManualUnread(forTabId: id)
        }
        syncUnreadBadgeStateForAllPanels()
    }

    private func notificationSnapshots(surfaceId: UUID?) -> [SessionNotificationSnapshot] {
        AppDelegate.shared?.notificationStore?
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

    private func applySessionDividerPositions(
        snapshotNode: SessionWorkspaceLayoutSnapshot,
        liveNode: ExternalTreeNode
    ) {
        switch (snapshotNode, liveNode) {
        case (.split(let snapshotSplit), .split(let liveSplit)):
            if let splitID = UUID(uuidString: liveSplit.id) {
                _ = bonsplitController.setDividerPosition(
                    CGFloat(snapshotSplit.dividerPosition),
                    forSplit: splitID,
                    fromExternal: true
                )
            }
            applySessionDividerPositions(snapshotNode: snapshotSplit.first, liveNode: liveSplit.first)
            applySessionDividerPositions(snapshotNode: snapshotSplit.second, liveNode: liveSplit.second)
        default:
            return
        }
    }
}

// MARK: - cmux.json custom layout

extension Workspace {

    func applyCustomLayout(_ layout: CmuxLayoutNode, baseCwd: String) {
        guard let rootPaneId = bonsplitController.allPaneIds.first else { return }

        var leaves: [(paneId: PaneID, surfaces: [CmuxSurfaceDefinition])] = []
        buildCustomLayoutTree(layout, inPane: rootPaneId, leaves: &leaves)

        // First leaf reuses the initial terminal created by addWorkspace;
        // subsequent leaves were created via newTerminalSplit which also seeds
        // a placeholder terminal.
        var focusPanelId: UUID?
        for leaf in leaves {
            populateCustomPane(leaf.paneId, surfaces: leaf.surfaces, baseCwd: baseCwd, focusPanelId: &focusPanelId)
        }

        let liveRoot = bonsplitController.treeSnapshot()
        applyCustomDividerPositions(configNode: layout, liveNode: liveRoot)

        if let focusPanelId {
            focusPanel(focusPanelId)
        }
    }

    private func buildCustomLayoutTree(
        _ node: CmuxLayoutNode,
        inPane paneId: PaneID,
        leaves: inout [(paneId: PaneID, surfaces: [CmuxSurfaceDefinition])]
    ) {
        switch node {
        case .pane(let pane):
            leaves.append((paneId: paneId, surfaces: pane.surfaces))

        case .split(let split):
            guard split.children.count == 2 else {
                #if DEBUG
                NSLog("[CmuxConfig] split node requires exactly 2 children, got %d", split.children.count)
                #endif
                leaves.append((paneId: paneId, surfaces: []))
                return
            }

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
                      orientation: split.splitOrientation,
                      insertFirst: false,
                      focus: false
                  ),
                  let secondPaneId = self.paneId(forPanelId: newSplitPanel.id) else {
                leaves.append((paneId: paneId, surfaces: []))
                return
            }

            buildCustomLayoutTree(split.children[0], inPane: paneId, leaves: &leaves)
            buildCustomLayoutTree(split.children[1], inPane: secondPaneId, leaves: &leaves)
        }
    }

    private func populateCustomPane(
        _ paneId: PaneID,
        surfaces: [CmuxSurfaceDefinition],
        baseCwd: String,
        focusPanelId: inout UUID?
    ) {
        let existingPanelIds = bonsplitController
            .tabs(inPane: paneId)
            .compactMap { panelIdFromSurfaceId($0.id) }

        guard !surfaces.isEmpty else { return }

        let firstSurface = surfaces[0]
        if let placeholderPanelId = existingPanelIds.first {
            configureExistingSurface(
                panelId: placeholderPanelId,
                inPane: paneId,
                surface: firstSurface,
                baseCwd: baseCwd,
                focusPanelId: &focusPanelId
            )
        }

        for surfaceIndex in 1..<surfaces.count {
            createNewSurface(
                inPane: paneId,
                surface: surfaces[surfaceIndex],
                baseCwd: baseCwd,
                focusPanelId: &focusPanelId
            )
        }
    }

    private func configureExistingSurface(
        panelId: UUID,
        inPane paneId: PaneID,
        surface: CmuxSurfaceDefinition,
        baseCwd: String,
        focusPanelId: inout UUID?
    ) {
        switch surface.type {
        case .terminal where surface.cwd != nil || surface.env != nil:
            // Placeholder can't change cwd/env — replace it
            let resolvedCwd = CmuxConfigStore.resolveCwd(surface.cwd, relativeTo: baseCwd)
            if let panel = newTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: resolvedCwd,
                startupEnvironment: surface.env ?? [:]
            ) {
                _ = closePanel(panelId, force: true)
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
                if let command = surface.command { sendInputWhenReady(command + "\n", to: panel) }
            }

        case .terminal:
            if let name = surface.name { setPanelCustomTitle(panelId: panelId, title: name) }
            if surface.focus == true { focusPanelId = panelId }
            if let command = surface.command, let terminal = terminalPanel(for: panelId) {
                sendInputWhenReady(command + "\n", to: terminal)
            }

        case .browser:
            let url = surface.url.flatMap { URL(string: $0) }
            if let panel = newBrowserSurface(
                inPane: paneId,
                url: url,
                focus: false,
                creationPolicy: .restoration
            ) {
                _ = closePanel(panelId, force: true)
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
            }

        case .project:
            if let panel = newProjectSurface(
                inPane: paneId,
                projectPath: surface.url ?? surface.cwd ?? "",
                focus: false
            ) {
                _ = closePanel(panelId, force: true)
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
            }
        }
    }

    private func createNewSurface(
        inPane paneId: PaneID,
        surface: CmuxSurfaceDefinition,
        baseCwd: String,
        focusPanelId: inout UUID?
    ) {
        switch surface.type {
        case .terminal:
            let resolvedCwd = CmuxConfigStore.resolveCwd(surface.cwd, relativeTo: baseCwd)
            if let panel = newTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: resolvedCwd,
                startupEnvironment: surface.env ?? [:]
            ) {
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
                if let command = surface.command { sendInputWhenReady(command + "\n", to: panel) }
            }

        case .browser:
            let url = surface.url.flatMap { URL(string: $0) }
            if let panel = newBrowserSurface(
                inPane: paneId,
                url: url,
                focus: false,
                creationPolicy: .restoration
            ) {
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
            }

        case .project:
            if let panel = newProjectSurface(
                inPane: paneId,
                projectPath: surface.url ?? surface.cwd ?? "",
                focus: false
            ) {
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
            }
        }
    }

    private func applyCustomDividerPositions(
        configNode: CmuxLayoutNode,
        liveNode: ExternalTreeNode
    ) {
        switch (configNode, liveNode) {
        case (.split(let configSplit), .split(let liveSplit)):
            if let splitID = UUID(uuidString: liveSplit.id) {
                _ = bonsplitController.setDividerPosition(
                    CGFloat(configSplit.clampedSplitPosition),
                    forSplit: splitID,
                    fromExternal: true
                )
            }
            if configSplit.children.count == 2 {
                applyCustomDividerPositions(configNode: configSplit.children[0], liveNode: liveSplit.first)
                applyCustomDividerPositions(configNode: configSplit.children[1], liveNode: liveSplit.second)
            }
        default:
            break
        }
    }

    private func sendInputWhenReady(
        _ text: String,
        to panel: TerminalPanel,
        reason: WorkspacePendingTerminalInputReason = .configurationCommand
    ) {
        if panel.surface.surface != nil {
            panel.sendInput(text)
            return
        }

        let timeout = reason.timeout
        let panelId = panel.id
        let registration = WorkspacePendingTerminalInputObserver()

        registration.observer = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: panel.surface,
            queue: .main
        ) { [weak self, registration] _ in
            Task { @MainActor [weak self, registration] in
                guard
                    let self,
                    self.hasPendingTerminalInputObserver(registration, forPanelId: panelId)
                else {
                    return
                }

                self.removePendingTerminalInputObserver(registration, forPanelId: panelId)
                if let panel = self.panels[panelId] as? TerminalPanel {
                    panel.sendInput(text)
                }
            }
        }
        pendingTerminalInputObserversByPanelId[panelId, default: []].append(registration)
        panel.surface.requestBackgroundSurfaceStartIfNeeded()

        guard let timeout else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self, registration] in
            Task { @MainActor [weak self, registration] in
                guard
                    let self,
                    self.hasPendingTerminalInputObserver(registration, forPanelId: panelId)
                else {
                    return
                }

                self.removePendingTerminalInputObserver(registration, forPanelId: panelId)
                #if DEBUG
                NSLog("[CmuxConfig] surface not ready after 3s, dropping command (%d chars)", text.count)
                #endif
            }
        }
    }

    private func hasPendingTerminalInputObserver(
        _ registration: WorkspacePendingTerminalInputObserver,
        forPanelId panelId: UUID
    ) -> Bool {
        pendingTerminalInputObserversByPanelId[panelId]?.contains {
            $0 === registration
        } == true
    }

    private func removePendingTerminalInputObserver(
        _ registration: WorkspacePendingTerminalInputObserver,
        forPanelId panelId: UUID
    ) {
        if let observer = registration.observer {
            NotificationCenter.default.removeObserver(observer)
            registration.observer = nil
        }
        pendingTerminalInputObserversByPanelId[panelId]?.removeAll {
            $0 === registration
        }
        if pendingTerminalInputObserversByPanelId[panelId]?.isEmpty == true {
            pendingTerminalInputObserversByPanelId.removeValue(forKey: panelId)
        }
    }

    func removePendingTerminalInputObservers(forPanelId panelId: UUID) {
        guard let observers = pendingTerminalInputObserversByPanelId.removeValue(forKey: panelId) else {
            return
        }
        for registration in observers {
            if let observer = registration.observer {
                NotificationCenter.default.removeObserver(observer)
                registration.observer = nil
            }
        }
    }

}


/// Lifted to `CmuxBrowser.ClosedBrowserPanelRestoreSnapshot` (Workspace
/// decomposition, Wave 3). This typealias keeps call sites byte-identical.
typealias ClosedBrowserPanelRestoreSnapshot = CmuxBrowser.ClosedBrowserPanelRestoreSnapshot

/// Process-wide, event-driven cache of `RestorableAgentSessionIndex.load()` results, used
/// by the right-click "Fork Conversation" availability check and the close-history undo
/// snapshot. `load()` runs `sysctl(KERN_PROCARGS2)` per hook record plus disk reads
/// (350ms-1.8s on large agent histories), far too expensive to do synchronously on the
/// main actor, so reloads run on a `Task.detached(priority: .utility)` and callers read
/// the cached snapshot synchronously.
///
/// Freshness is driven by a watcher on the hook-store directory (`~/.cmuxterm`), which the
/// `cmux hooks` CLI writes when an agent session starts or updates. The cache reloads
/// shortly after an actual change (coalesced + rate-limited) and otherwise idles, with a
/// long fallback TTL for pull access. This replaced a 1s pull TTL that reloaded
/// near-continuously while the sidebar was visible, because each load outlasts a 1s TTL.
///
/// `ObservableObject` conformance lets each workspace forward `objectWillChange` when a
/// reload lands so ContentView re-renders and bonsplit's TabBarView picks up the new
/// snapshot on the same frame.
@MainActor
final class SharedLiveAgentIndex: ObservableObject {
    static let shared = SharedLiveAgentIndex()

    @Published private(set) var index: RestorableAgentSessionIndex?
    private var loadedAt: Date?
    private var refreshTask: Task<Void, Never>?
    // A hook-store change arrived while a reload was in flight; reload again after.
    private var changePending = false
    // Holds a pending rate-limited reload when changes arrive faster than the floor.
    private var deferredReloadTask: Task<Void, Never>?

    // The directory watcher is the primary freshness mechanism; pull access only needs an
    // occasional safety refresh.
    private static let cacheTTL: TimeInterval = 60.0
    // Floor between event-driven reloads so a chatty agent cannot thrash the ~1.6s loader.
    private static let minEventReloadInterval: TimeInterval = 2.0

    private var directoryWatchSource: DispatchSourceFileSystemObject?
    private let watchQueue = DispatchQueue(label: "com.cmuxterm.app.sharedLiveAgentIndexWatch")

    private init() {}

    /// Read the cached snapshot for the given (workspaceId, panelId). Never blocks.
    func snapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        scheduleRefreshIfStale()
        return index?.snapshot(workspaceId: workspaceId, panelId: panelId)
    }

    /// Current cached index. Never blocks. Used by the close-history undo snapshot so
    /// closing a tab does not pay the synchronous `RestorableAgentSessionIndex.load()`
    /// cost on the main thread. The directory watcher keeps this current; stale tolerance
    /// is fine because restore/resume re-reads transcripts from disk and only uses the
    /// cached snapshot's session identity, not the live PID set.
    func currentIndexSchedulingRefresh() -> RestorableAgentSessionIndex? {
        scheduleRefreshIfStale()
        return index
    }

    /// Ensure the hook-store watcher is running and refresh if the cache has aged past the
    /// long fallback TTL. The watcher, not this TTL, is the primary freshness path.
    func scheduleRefreshIfStale() {
        ensureWatchingHookStoreDirectory()
        guard refreshTask == nil else { return }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < Self.cacheTTL {
            return
        }
        startReload()
    }

    private func startReload() {
        deferredReloadTask?.cancel()
        deferredReloadTask = nil
        refreshTask = Task { @MainActor [weak self] in
            let newIndex = await Task.detached(priority: .utility) {
                // agent-index-load-ok: off-main cache loader (this IS the sanctioned home
                // for load(); everything else should read SharedLiveAgentIndex.shared).
                RestorableAgentSessionIndex.load()
            }.value
            guard let self else { return }
            // Assigning to `@Published` fires objectWillChange, which subscribed
            // workspaces forward as their own objectWillChange so SwiftUI re-renders.
            self.index = newIndex
            self.loadedAt = Date()
            self.refreshTask = nil
            if self.changePending {
                self.changePending = false
                self.handleHookStoreChange()
            }
        }
    }

    /// Coalesce and rate-limit reloads triggered by hook-store directory changes.
    private func handleHookStoreChange() {
        if refreshTask != nil {
            changePending = true
            return
        }
        let elapsed = loadedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if elapsed >= Self.minEventReloadInterval {
            startReload()
        } else if deferredReloadTask == nil {
            // Bounded, cancellable delay to honor the reload floor (not a sync
            // substitute): wait the remainder, then re-evaluate.
            let wait = Self.minEventReloadInterval - elapsed
            deferredReloadTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                self.deferredReloadTask = nil
                self.handleHookStoreChange()
            }
        }
    }

    private func ensureWatchingHookStoreDirectory() {
        guard directoryWatchSource == nil else { return }
        let dir = RestorableAgentKind.claude
            .hookStoreFileURL()
            .deletingLastPathComponent()
            .path
        // Ensure the hook-store directory exists so the watcher installs at launch and
        // observes the very first hook write. On a fresh/cleaned install it would
        // otherwise not exist yet, the watcher would not install, and the first agent's
        // session could stay invisible behind the fallback TTL. This is cmux's own state
        // directory (the `cmux hooks` CLI writes here too), so creating it empty is benign.
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            // Directory still unavailable (e.g. permissions); retried on the next
            // scheduleRefreshIfStale() (sidebar render / close).
            return
        }
        // A directory-level kqueue source reports entry changes (create/delete/rename) but
        // not in-place data writes to an existing child file. That is sufficient here
        // because every hook-store write is atomic (write-temp + rename, e.g.
        // ClaudeHookSessionStore.saveUnlocked uses `.write(options: .atomic)`), so each
        // update lands as a rename into this directory and fires the source. This matches
        // cmux's existing CmuxConfig watcher, which relies on the same atomic-write
        // invariant. The 60s fallback TTL backstops anything a future non-atomic writer
        // to ~/.cmuxterm might add.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename],
            queue: watchQueue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.handleHookStoreChange() }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        directoryWatchSource = source
        // The watcher may have just been installed after `~/.cmuxterm` first appeared
        // (first run / cleaned state); any hook writes before this moment were unobserved
        // and an earlier empty load may have stamped a "fresh" loadedAt that would
        // suppress the fallback-TTL reload. Force a catch-up reload now.
        if refreshTask == nil {
            startReload()
        } else {
            changePending = true
        }
    }
}

/// Workspace represents a sidebar tab.
/// Each workspace contains one BonsplitController that manages split panes and nested surfaces.
@MainActor
final class Workspace: Identifiable, ObservableObject {
    enum BrowserPanelCreationPolicy {
        case userInitiated
        case automationPreload
        case restoration

        var permitsCreationWhenBrowserDisabled: Bool {
            self == .restoration
        }

        var preloadsInitialNavigationInBackground: Bool {
            self == .automationPreload
        }
    }

    static let terminalScrollBarHiddenDidChangeNotification = Notification.Name(
        "cmux.workspaceTerminalScrollBarHiddenDidChange"
    )

    let id: UUID
    /// When this workspace instance came into existence in this app session
    /// (creation, or restore at launch). The mobile list's last-activity
    /// fallback: a workspace that never fired a notification still carries a
    /// real timestamp instead of nothing.
    let createdAt = Date()
    @Published var title: String
    @Published var customTitle: String?
    /// Provenance of `customTitle`: `.user` for manual renames (sidebar,
    /// CLI, command palette), `.auto` for AI auto-naming. `nil` when no
    /// custom title is set. A present title with absent provenance is
    /// treated as `.user` so auto-naming never overwrites a title it
    /// cannot prove it owns.
    @Published var customTitleSource: CustomTitleSource?
    @Published var customDescription: String?
    @Published var isPinned: Bool = false
    /// Identifier of the WorkspaceGroup this workspace belongs to, or nil if ungrouped.
    /// The group entity itself lives in `TabManager.workspaceGroups`.
    @Published var groupId: UUID?
    @Published var customColor: String?  // hex string, e.g. "#C0392B"
    /// User-defined environment variables applied to every shell spawned in this
    /// workspace: the initial terminal, every later pane/surface/split, and every
    /// surface recreated on session restore. Managed `CMUX_*` and terminal-identity
    /// variables always win — this dictionary is merged through the
    /// `additionalEnvironment` / `initialEnvironmentOverrides` channels, both of
    /// which skip `protectedStartupEnvironmentKeys` in
    /// `mergedStartupEnvironment(...)`, so a workspace env entry can never clobber
    /// the variables the daemon relies on (CMUX_WORKSPACE_ID, CMUX_SOCKET_PATH, …).
    /// Persisted in the session manifest and restored before surfaces are rebuilt.
    @Published var workspaceEnvironment: [String: String] = [:]
    // Legacy in-memory state for old helpers/tests. Product UI, rendering, and
    // session persistence no longer honor per-workspace scrollbar overrides.
    @Published private(set) var terminalScrollBarHidden: Bool = false
    @Published var currentDirectory: String {
        didSet {
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
    @Published private(set) var extensionSidebarProjectRootPath: String?
    private var extensionSidebarProjectRootRefreshID: UInt64 = 0
    @Published private(set) var surfaceTabBarDirectory: String?
    private(set) var preferredBrowserProfileID: UUID?
    let closeTabWarningDefaults, agentSessionAutoResumeDefaults: UserDefaults
    /// Ordinal for CMUX_PORT range assignment (monotonically increasing per app session)
    var portOrdinal: Int = 0

    /// The bonsplit controller managing the split panes for this workspace
    let bonsplitController: BonsplitController

    /// How this workspace lays out its panels. Mutate through
    /// `setLayoutMode(_:)` (Workspace+CanvasLayout.swift) so canvas frames
    /// are seeded from the split layout on first entry.
    @Published var layoutMode: WorkspaceLayoutMode = .splits

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

    /// The surface-registry sub-model (CmuxWorkspaceCore): owns the
    /// per-surface registry annotations (tty names, shell-activity states)
    /// and the transient tab-selection/focus-reassert request state. The
    /// legacy accessors below forward here. None of the moved properties
    /// were `@Published`, so no observer hooks are required.
    private let surfaceRegistry = SurfaceRegistryModel<PendingTabSelectionRequest>()

    /// The split-layout sub-model (CmuxPanes): owns the split/detach
    /// choreography bookkeeping (programmatic-split flag, detaching surface
    /// ids, captured transfer payloads, detach-close transaction count). The
    /// legacy accessors below forward here. None of the moved properties
    /// were `@Published`, so no observer hooks are required.
    private let splitLayout = SplitLayoutModel<DetachedSurfaceTransfer>()

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

    /// Aggregate media-device activity across every browser pane in this
    /// workspace (audio / microphone / camera), surfaced to the sidebar
    /// workspace row so a noisy or capturing background pane is discoverable.
    private(set) var browserMediaActivity = BrowserMediaActivity()

    /// When true, suppresses auto-creation in didSplitPane (programmatic splits handle their own panels);
    /// stored in the split-layout sub-model.
    var isProgrammaticSplit: Bool {
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

    /// Published directory for each panel
    @Published var panelDirectories: [UUID: String] = [:]
    @Published var panelTitles: [UUID: String] = [:]
    @Published var panelCustomTitles: [UUID: String] = [:]
    /// Provenance of entries in `panelCustomTitles` (see ``CustomTitleSource``).
    /// An entry may be absent for a title carried across panel moves or
    /// restored from older snapshots; absent provenance is treated as `.user`.
    var panelCustomTitleSources: [UUID: CustomTitleSource] = [:]
    @Published var pinnedPanelIds: Set<UUID> = []
    @Published var manualUnreadPanelIds: Set<UUID> = [] {
        didSet {
            guard manualUnreadPanelIds != oldValue else { return }
            syncPanelDerivedWorkspaceUnread()
        }
    }
    @Published private var restoredUnreadPanelIndicators: [UUID: RestoredPanelUnreadIndicator] = [:] {
        didSet {
            guard restoredUnreadPanelIndicators != oldValue else { return }
            syncPanelDerivedWorkspaceUnread()
        }
    }
    var restoredUnreadPanelIds: Set<UUID> {
        Set(restoredUnreadPanelIndicators.keys)
    }
    @Published private(set) var tmuxLayoutSnapshot: LayoutSnapshot?
    @Published private(set) var tmuxWorkspaceFlashPanelId: UUID?
    @Published private(set) var tmuxWorkspaceFlashReason: WorkspaceAttentionFlashReason?
    @Published private(set) var tmuxWorkspaceFlashToken: UInt64 = 0
    var manualUnreadMarkedAt: [UUID: Date] = [:]
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
    @Published private(set) var latestConversationMessage: String?
    @Published private(set) var latestSubmittedMessage: String?
    @Published private(set) var latestSubmittedAt: Date?
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
    @Published var surfaceListeningPorts: [UUID: [Int]] = [:]
    var agentListeningPorts: [Int] = []
    @Published var remoteConfiguration: WorkspaceRemoteConfiguration?
    @Published var remoteConnectionState: WorkspaceRemoteConnectionState = .disconnected
    @Published var remoteConnectionDetail: String?
    @Published var remoteDaemonStatus: WorkspaceRemoteDaemonStatus = WorkspaceRemoteDaemonStatus()
    @Published var remoteDetectedPorts: [Int] = []
    @Published var remoteForwardedPorts: [Int] = []
    @Published var remotePortConflicts: [Int] = []
    @Published var remoteProxyEndpoint: BrowserProxyEndpoint?
    @Published var remoteHeartbeatCount: Int = 0
    @Published var remoteLastHeartbeatAt: Date?
    @Published var listeningPorts: [Int] = []
    @Published private(set) var activeRemoteTerminalSessionCount: Int = 0
    /// The controlling-terminal device name per panel id; stored in the
    /// surface-registry sub-model.
    var surfaceTTYNames: [UUID: String] {
        get { surfaceRegistry.surfaceTTYNames }
        set { surfaceRegistry.surfaceTTYNames = newValue }
    }
    private var remoteSessionController: RemoteSessionCoordinator?
    private var pendingRemoteForegroundAuthToken: String?
    var activeRemoteSessionControllerID: UUID?
    private var remoteLastErrorFingerprint: String?
    private var remoteLastDaemonErrorFingerprint: String?
    private var remoteLastPortConflictFingerprint: String?
    private var remoteDetectedSurfaceIds: Set<UUID> = []
    private var activeRemoteTerminalSurfaceIds: Set<UUID> = []
    private var endedPersistentRemotePTYAttachSurfaceIds: Set<UUID> = []
    private var remotePTYSessionIDsByPanelId: [UUID: String] = [:]
    private var remoteRelayWorkspaceIDAliases: [UUID: UUID] = [:]
    private var remoteRelaySurfaceIDAliases: [UUID: UUID] = [:]
    private var suppressRemoteTerminalStartupForSessionRestoreScaffold = false
    var pendingRemoteTerminalChildExitSurfaceIds: Set<UUID> = []

    private struct PendingRemoteDisconnectReplacement {
        let target: String
        let reconnectCommand: String?
    }

    /// Remote disconnect metadata used by `createReplacementTerminalPanel()`.
    private var pendingRemoteDisconnectReplacement: PendingRemoteDisconnectReplacement?
    var remoteDisconnectPlaceholderPanelIds: Set<UUID> = []

    private static let remoteErrorStatusKey = "remote.error"
    private static let remotePortConflictStatusKey = "remote.port_conflicts"
    private static let remoteNotificationCooldown: TimeInterval = 5 * 60
    private static let sshControlMasterCleanupQueue = DispatchQueue(
        label: "com.cmux.remote-ssh.control-master-cleanup",
        qos: .utility
    )
    private static let remoteHeartbeatDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) static var runSSHControlMasterCommandOverrideForTesting: (([String]) -> Void)?
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
    /// PIDs associated with agent status entries (e.g. claude_code), keyed by status key.
    /// Used for stale-session detection: if the PID is dead, the status entry is cleared.
    var agentPIDs: [String: pid_t] = [:]
    var agentPIDPanelIdsByKey: [String: UUID] = [:]
    var agentPIDKeysByPanelId: [UUID: Set<String>] = [:]
    var agentLifecycleStatesByPanelId: [UUID: [String: AgentHibernationLifecycleState]] = [:]
    var restoredTerminalScrollbackByPanelId: [UUID: String] = [:]
#if DEBUG
    var debugSessionSnapshotScrollbackFallbackPanelIds: Set<UUID> = []
    var debugSessionSnapshotSyntheticScrollbackByPanelId: [UUID: String] = [:]
#endif
    var restoredAgentSnapshotsByPanelId: [UUID: SessionRestorableAgentSnapshot] = [:]
    var surfaceResumeBindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot] = [:]
    private var restoredGuardedWorkingDirectoriesByPanelId: [UUID: String] = [:]
    enum RestoredAgentResumeState: Equatable {
        case manualResumeAvailable
        case awaitingAutoResumeCommand
        case autoResumeCommandRunning
        case observedAgentCommandRunning
    }
    var restoredAgentResumeStatesByPanelId: [UUID: RestoredAgentResumeState] = [:]
    var invalidatedRestoredAgentFingerprintsByPanelId: [UUID: Int] = [:]
    private var pendingTerminalInputObserversByPanelId: [UUID: [WorkspacePendingTerminalInputObserver]] = [:]
    private let sessionRestorePolicy: WorkspaceSessionRestorePolicyService<SurfaceResumeBindingSnapshot>

    typealias SurfaceResumeStartupLaunch = WorkspaceSurfaceResumeStartupLaunch

    // Sidebar rows cache snapshots, so observation must begin with the current
    // workspace state. Build state publishers from @Published current values
    // instead of dropping the first value and repairing timing with a Void event.
    lazy var sidebarImmediateObservationPublisher: AnyPublisher<Void, Never> = makeSidebarImmediateObservationPublisher()
    lazy var sidebarObservationPublisher: AnyPublisher<Void, Never> = makeSidebarObservationPublisher()

    private func scheduleExtensionSidebarProjectRootRefresh(for directory: String) {
        extensionSidebarProjectRootRefreshID &+= 1
        let refreshID = extensionSidebarProjectRootRefreshID
        guard !isRemoteWorkspace else {
            extensionSidebarProjectRootPath = nil
            return
        }
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

    private static func isProxyOnlyRemoteError(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("remote proxy")
            || lowered.contains("proxy_unavailable")
            || lowered.contains("local daemon proxy")
            || lowered.contains("proxy failure")
            || lowered.contains("daemon transport")
    }

    private var preservesProxyFailureWhileSSHTerminalIsAlive: Bool {
        remoteConfiguration?.transport == .ssh
            && activeRemoteTerminalSessionCount > 0
            && remoteConfiguration?.terminalStartupCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var hasProxyOnlyRemoteSidebarError: Bool {
        guard let entry = statusEntries[Self.remoteErrorStatusKey]?.value else { return false }
        return entry.lowercased().contains("remote proxy unavailable")
    }

    private func remoteNotificationCooldownKey(target: String) -> String? {
        let rawTarget = (remoteConfiguration?.destination ?? target)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTarget.isEmpty else { return nil }
        let normalizedHost = rawTarget
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalizedHost, !normalizedHost.isEmpty else { return nil }
        return "remote-host:\(normalizedHost)"
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
                SurfaceResumeApprovalStore.applyingStoredApproval(
                    to: binding,
                    fileURL: fileURL,
                    signingSecret: signingSecret
                )
            },
            shouldRunPromptedSurfaceResume: { binding in
                Self.shouldRunPromptedSurfaceResume(binding)
            },
            isRunningUnderAutomatedTests: {
                SessionRestorePolicy.isRunningUnderAutomatedTests()
            },
            truncateScrollback: { text in
                SessionPersistencePolicy.truncatedScrollback(text)
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

    nonisolated static func usesWindowRootTerminalBackdrop() -> Bool {
        true
    }

    nonisolated static func bonsplitChromeHex(
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        sharesWindowBackdrop: Bool = false
    ) -> String {
        _ = sharesWindowBackdrop
        let themedColor = WindowAppearanceSnapshot.compositedTerminalColor(
            backgroundColor: backgroundColor,
            opacity: backgroundOpacity
        )
        let includeAlpha = themedColor.alphaComponent < 0.999
        return themedColor.hexString(includeAlpha: includeAlpha)
    }

    nonisolated static func usesBonsplitPaneTerminalBackdrop(
        renderingMode: GhosttyTerminalBackdropRenderingMode,
        sharesWindowBackdrop: Bool
    ) -> Bool {
        // The window root backdrop owns terminal fills. Bonsplit pane fills
        // would add a second translucent layer under the Metal surface.
        return false
    }

    nonisolated static func bonsplitChromeColors(
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        sharesWindowBackdrop: Bool = false,
        renderingMode: GhosttyTerminalBackdropRenderingMode = .windowHostBackdrop
    ) -> BonsplitConfiguration.Appearance.ChromeColors {
        let surfaceHex = bonsplitChromeHex(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop
        )
        let borderHex = WindowChromeColorResolver()
            .separatorColor(forChromeBackground: backgroundColor)
            .hexString(includeAlpha: true)

        if sharesWindowBackdrop {
            return .init(
                backgroundHex: surfaceHex,
                tabBarBackgroundHex: "#00000000",
                splitButtonBackdropHex: "#00000000",
                paneBackgroundHex: "#00000000",
                borderHex: borderHex
            )
        }

        let paneBackgroundHex = usesBonsplitPaneTerminalBackdrop(
            renderingMode: renderingMode,
            sharesWindowBackdrop: sharesWindowBackdrop
        )
            ? surfaceHex
            : "#00000000"
        return .init(
            backgroundHex: surfaceHex,
            tabBarBackgroundHex: surfaceHex,
            splitButtonBackdropHex: surfaceHex,
            paneBackgroundHex: paneBackgroundHex,
            borderHex: borderHex
        )
    }

    nonisolated static func resolvedChromeColors(
        from backgroundColor: NSColor,
        sharesWindowBackdrop: Bool = false,
        renderingMode: GhosttyTerminalBackdropRenderingMode = .windowHostBackdrop
    ) -> BonsplitConfiguration.Appearance.ChromeColors {
        // Keep this signature aligned with bonsplitChromeHex for settings tests
        // and future background-image handling.
        let backgroundHex = backgroundColor.hexString()
        let borderHex = WindowChromeColorResolver()
            .separatorColor(forChromeBackground: backgroundColor)
            .hexString(includeAlpha: true)

        if sharesWindowBackdrop {
            return .init(
                backgroundHex: backgroundHex,
                tabBarBackgroundHex: "#00000000",
                splitButtonBackdropHex: "#00000000",
                paneBackgroundHex: "#00000000",
                borderHex: borderHex
            )
        }

        let paneBackgroundHex = usesBonsplitPaneTerminalBackdrop(
            renderingMode: renderingMode,
            sharesWindowBackdrop: sharesWindowBackdrop
        )
            ? backgroundHex
            : "#00000000"
        return .init(
            backgroundHex: backgroundHex,
            tabBarBackgroundHex: backgroundHex,
            splitButtonBackdropHex: backgroundHex,
            paneBackgroundHex: paneBackgroundHex,
            borderHex: borderHex
        )
    }

    private static func bonsplitChromeColorsEqual(
        _ lhs: BonsplitConfiguration.Appearance.ChromeColors,
        _ rhs: BonsplitConfiguration.Appearance.ChromeColors
    ) -> Bool {
        lhs.backgroundHex == rhs.backgroundHex &&
            lhs.tabBarBackgroundHex == rhs.tabBarBackgroundHex &&
            lhs.splitButtonBackdropHex == rhs.splitButtonBackdropHex &&
            lhs.paneBackgroundHex == rhs.paneBackgroundHex &&
            lhs.borderHex == rhs.borderHex
    }

    private static func bonsplitChromeColorsLogDescription(
        _ colors: BonsplitConfiguration.Appearance.ChromeColors
    ) -> String {
        "bg=\(colors.backgroundHex ?? "nil") " +
            "tabBarBg=\(colors.tabBarBackgroundHex ?? "nil") " +
            "splitBackdrop=\(colors.splitButtonBackdropHex ?? "nil") " +
            "paneBg=\(colors.paneBackgroundHex ?? "nil") " +
            "border=\(colors.borderHex ?? "nil")"
    }

    private static func bonsplitAppearance(
        from backgroundColor: NSColor,
        backgroundOpacity: Double,
        tabTitleFontSize: CGFloat = 11
    ) -> BonsplitConfiguration.Appearance {
        let sharesWindowBackdrop = usesWindowRootTerminalBackdrop()
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
        )
        let chromeColors = Self.bonsplitChromeColors(
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
        let sharesWindowBackdrop = Self.usesWindowRootTerminalBackdrop()
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
        )
        let nextChromeColors = Self.bonsplitChromeColors(
            backgroundColor: config.backgroundColor,
            backgroundOpacity: config.backgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            renderingMode: renderingMode
        )
        let nextTabTitleFontSize = config.surfaceTabBarFontSize
        let currentAppearance = bonsplitController.configuration.appearance
        let currentTabTitleFontSize = currentAppearance.tabTitleFontSize
        let colorsChanged = !Self.bonsplitChromeColorsEqual(
            currentAppearance.chromeColors,
            nextChromeColors
        )
        let sharedBackdropChanged = currentAppearance.usesSharedBackdrop != sharesWindowBackdrop
        let fontSizeChanged = abs(currentTabTitleFontSize - nextTabTitleFontSize) > 0.0001
        let isNoOp = !colorsChanged && !sharedBackdropChanged && !fontSizeChanged

        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme apply workspace=\(id.uuidString) reason=\(reason) " +
                "current=[\(Self.bonsplitChromeColorsLogDescription(currentAppearance.chromeColors))] " +
                "next=[\(Self.bonsplitChromeColorsLogDescription(nextChromeColors))] " +
                "currentTabFont=\(String(format: "%.3f", currentTabTitleFontSize)) " +
                "nextTabFont=\(String(format: "%.3f", nextTabTitleFontSize)) " +
                "sharesWindowBackdrop=\(sharesWindowBackdrop ? 1 : 0) " +
                "currentUsesSharedBackdrop=\(currentAppearance.usesSharedBackdrop ? 1 : 0) " +
                "paneBackdrop=\(Self.usesBonsplitPaneTerminalBackdrop(renderingMode: renderingMode, sharesWindowBackdrop: sharesWindowBackdrop) ? 1 : 0) " +
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
                "resulting=[\(Self.bonsplitChromeColorsLogDescription(bonsplitController.configuration.appearance.chromeColors))] " +
                "resultingUsesSharedBackdrop=\(bonsplitController.configuration.appearance.usesSharedBackdrop ? 1 : 0) " +
                "resultingTabFont=\(String(format: "%.3f", bonsplitController.configuration.appearance.tabTitleFontSize))"
            )
        }
    }

    func applyGhosttyChrome(backgroundColor: NSColor, backgroundOpacity: Double, reason: String = "unspecified") {
        let sharesWindowBackdrop = Self.usesWindowRootTerminalBackdrop()
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
        )
        let nextChromeColors = Self.bonsplitChromeColors(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            renderingMode: renderingMode
        )
        let currentChromeColors = bonsplitController.configuration.appearance.chromeColors
        let currentUsesSharedBackdrop = bonsplitController.configuration.appearance.usesSharedBackdrop
        let colorsChanged = !Self.bonsplitChromeColorsEqual(currentChromeColors, nextChromeColors)
        let sharedBackdropChanged = currentUsesSharedBackdrop != sharesWindowBackdrop
        let isNoOp = !colorsChanged && !sharedBackdropChanged

        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme apply workspace=\(id.uuidString) reason=\(reason) " +
                "current=[\(Self.bonsplitChromeColorsLogDescription(currentChromeColors))] " +
                "next=[\(Self.bonsplitChromeColorsLogDescription(nextChromeColors))] " +
                "sharesWindowBackdrop=\(sharesWindowBackdrop ? 1 : 0) " +
                "currentUsesSharedBackdrop=\(currentUsesSharedBackdrop ? 1 : 0) " +
                "paneBackdrop=\(Self.usesBonsplitPaneTerminalBackdrop(renderingMode: renderingMode, sharesWindowBackdrop: sharesWindowBackdrop) ? 1 : 0) " +
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
                "resulting=[\(Self.bonsplitChromeColorsLogDescription(bonsplitController.configuration.appearance.chromeColors))] " +
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
        closeTabWarningDefaults: UserDefaults = .standard,
        agentSessionAutoResumeDefaults: UserDefaults = .standard,
        initialDetachedSurface: DetachedSurfaceTransfer? = nil,
        sessionRestorePolicy: WorkspaceSessionRestorePolicyService<SurfaceResumeBindingSnapshot>? = nil
    ) {
        self.id = UUID()
        self.sessionRestorePolicy = sessionRestorePolicy ?? Self.makeSessionRestorePolicyService()
        self.closeTabWarningDefaults = closeTabWarningDefaults
        self.agentSessionAutoResumeDefaults = agentSessionAutoResumeDefaults
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
        self.currentDirectory = initialDirectory
        self.surfaceTabBarDirectory = initialDirectory

        // Preserve terminal state and inherit tab-strip sizing without repeated config parsing.
        let initialSurfaceTabBarFontSize = GhosttyConfig.load(globalFontMagnificationPercent: GlobalFontMagnification.storedPercent).surfaceTabBarFontSize
        let appearance = Self.bonsplitAppearance(
            from: GhosttyApp.shared.defaultBackgroundColor,
            backgroundOpacity: GhosttyApp.shared.defaultBackgroundOpacity,
            tabTitleFontSize: initialSurfaceTabBarFontSize
        )
        let config = BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: !CloseTabWarningStore(defaults: closeTabWarningDefaults).hidesTabCloseButton,
            allowCloseLastPane: false,
            allowTabReordering: true,
            allowCrossPaneTabMove: true,
            autoCloseEmptyPanes: true,
            contentViewLifecycle: .keepAllAlive,
            newTabPosition: .current,
            appearance: appearance
        )
        self.bonsplitController = BonsplitController(configuration: config)
        paneTree.attach(host: self)
        surfaceList.attach(tree: self)
        bonsplitController.contextMenuShortcuts = Self.buildContextMenuShortcuts()

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
                isAudioPlaying: browserPanel.isPlayingAudio,
                isPinned: false
            ) {
                bindSurface(tabId, toPanelId: browserPanel.id)
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
                bindSurface(tabId, toPanelId: terminalPanel.id)
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
            self?.bonsplitTabMoveDestinations(for: tabId) ?? []
        }
        bonsplitController.tabContextForkConversationAvailabilityProvider = { [weak self] tabId, _ in
            guard let self,
                  let panelId = self.panelIdFromSurfaceId(tabId) else { return false }
            return self.canForkAgentConversationFromPanel(panelId)
        }
        bonsplitController.tabContextForkConversationDefaultActionProvider = { _, _ in
            AgentConversationForkDefaultSettings.current().tabContextAction
        }
        bonsplitController.onTabCloseRequest = { [weak self] tabId, _, source in
            switch source {
            case .closeButton:
                self?.markTabCloseButtonClose(surfaceId: tabId)
            case .middleClick:
                self?.markTabStripMiddleClickClose(surfaceId: tabId)
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

        // Forward shared agent-index refreshes as our own objectWillChange so the bonsplit
        // tab-bar re-evaluates the Fork Conversation availability the moment a background
        // refresh lands.
        sharedLiveAgentIndexCancellable = SharedLiveAgentIndex.shared.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private var sharedLiveAgentIndexCancellable: AnyCancellable?

    deinit {
        for registrations in pendingTerminalInputObserversByPanelId.values {
            for registration in registrations {
                if let observer = registration.observer {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }
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
        let allowCloseTabs = !CloseTabWarningStore(defaults: closeTabWarningDefaults).hidesTabCloseButton
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

    /// Mapping from bonsplit TabID (surface id) to the owning panel id;
    /// stored in the pane-tree sub-model.
    var surfaceIdToPanelId: [TabID: UUID] {
        paneTree.surfaceIdToPanelId
    }

    /// Registers a bonsplit surface as the active owner for a panel.
    func bindSurface(_ surfaceId: TabID, toPanelId panelId: UUID) {
        paneTree.bindSurface(surfaceId, toPanelId: panelId)
    }

    /// Removes one bonsplit surface mapping.
    func removeSurfaceMapping(forSurfaceId surfaceId: TabID) {
        paneTree.removeSurfaceMapping(forSurfaceId: surfaceId)
    }

    /// Removes every bonsplit surface mapping for a closed panel.
    func removeSurfaceMappings(forPanelId panelId: UUID) {
        paneTree.removeSurfaceMappings(forPanelId: panelId)
    }

    /// Tab IDs that are allowed to close even if they would normally require confirmation.
    /// This is used by app-level confirmation prompts (for example, Close Tab) so the
    /// Bonsplit delegate doesn't block the close after the user already confirmed.
    private var forceCloseTabIds: Set<TabID> = []

    /// Tab IDs that are currently showing (or about to show) a close confirmation prompt.
    /// Prevents repeated close gestures (e.g., middle-click spam) from stacking dialogs.
    private var pendingCloseConfirmTabIds: Set<TabID> = []

    /// tmux pane ids (multi-pane mirror ✕) with a close-time activity query or
    /// confirmation in flight, so click spam can't double-kill or stack dialogs.
    private var pendingRemoteTmuxPaneCloseIds: Set<Int> = []

    /// User-initiated close attempts, distinct from internal close/move flows.
    private var explicitUserCloseTabIds: Set<TabID> = []
    private var closeHistoryEligibleTabIds: Set<TabID> = []
    private var closeHistoryEligiblePanelIds: Set<UUID> = []
    private var suppressClosedPanelHistory = false
    private var tabStripCloseButtonByTabId: [TabID: Bool] = [:]
    private var remoteTmuxWorkspaceCloseButtonByTabId: [TabID: Bool] = [:]
    private var remoteTmuxKeepWorkspaceOpenTabIds: Set<TabID> = []
    private var remoteTmuxKeepWorkspaceOpenAfterSessionEnd = false
    /// Deterministic tab selection to apply after a tab closes, keyed by closing tab ID.
    private var postCloseSelectTabId: [TabID: TabID] = [:]
    private var postCloseClearSplitZoomTabIds: Set<TabID> = []
    /// Panel IDs that were in a pane when a pane-close operation was approved.
    /// Bonsplit pane-close does not emit per-tab didClose callbacks.
    private var pendingPaneClosePanelIds: [UUID: [UUID]] = [:]
    private var pendingPaneCloseHistoryEntries: [UUID: [ClosedPanelHistoryEntry]] = [:]
    private var pendingClosedBrowserRestoreSnapshots: [TabID: ClosedBrowserPanelRestoreSnapshot] = [:]
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
    private var layoutFollowUpObservers: [NSObjectProtocol] = []
    private var layoutFollowUpPanelsCancellable: AnyCancellable?
    private var layoutFollowUpTimeoutWorkItem: DispatchWorkItem?
    private var layoutFollowUpReason: String?
    private var layoutFollowUpTerminalFocusPanelId: UUID?
    private var layoutFollowUpBrowserPanelId: UUID?
    private var layoutFollowUpBrowserExitFocusPanelId: UUID?
    private var layoutFollowUpNeedsGeometryPass = false
    private var layoutFollowUpAttemptScheduled = false
    private var layoutFollowUpAttemptVersion: Int = 0
    private var layoutFollowUpStalledAttemptCount = 0
    private var pendingReparentFocusSuppressionViews: [ObjectIdentifier: GhosttySurfaceScrollView] = [:]
    private var portalRenderingEnabled = true
    private var agentHibernationAutoResumePresentationVisible = true
    private var isAttemptingLayoutFollowUp = false
    private var isNormalizingPinnedTabOrder = false
    /// The pending non-focusing-split focus re-assert request (the value
    /// type now lives in CmuxWorkspaceCore); stored in the surface-registry
    /// sub-model.
    private var pendingNonFocusSplitFocusReassert: PendingNonFocusSplitFocusReassert? {
        get { surfaceRegistry.pendingNonFocusSplitFocusReassert }
        set { surfaceRegistry.pendingNonFocusSplitFocusReassert = newValue }
    }
    /// Monotonic focus re-assert generation counter; stored in the
    /// surface-registry sub-model.
    private var nonFocusSplitFocusReassertGeneration: UInt64 {
        get { surfaceRegistry.nonFocusSplitFocusReassertGeneration }
        set { surfaceRegistry.nonFocusSplitFocusReassertGeneration = newValue }
    }

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
    private var isDetachingCloseTransaction: Bool { splitLayout.isDetachingCloseTransaction }
    /// True while ``reorderRemoteTmuxMirrorTabs(toPanelOrder:)`` is rearranging tabs.
    /// bonsplit's `reorderTab`/`selectTab`/`focusPane` fire `didSelectTab` /
    /// `didFocusPane`, each of which runs the full `applyTabSelection` activation
    /// (focus moves, hibernation resume, focus-LRU record). A reactive tmux-driven
    /// reorder must not run any of that because the user's selection/focus is unchanged.
    private var isApplyingRemoteTmuxTabReorder = false
    private var pendingRemoteSurfaceTTYName: String?
    private var pendingRemoteSurfaceTTYSurfaceId: UUID?
    private var pendingRemoteSurfacePortKickReason: PortScanKickReason?
    private var pendingRemoteSurfacePortKickSurfaceId: UUID?
    private var pendingRemoteSurfacePWD: String?
    private var pendingRemoteSurfacePWDSurfaceId: UUID?
    // When the last live remote terminal is detached out, the source workspace may be
    // closed immediately after the move succeeds. That teardown must not shut down the
    // shared SSH control master that is still serving the moved terminal.
    private var skipControlMasterCleanupAfterDetachedRemoteTransfer = false
    var transferredRemoteCleanupConfigurationsByPanelId: [UUID: WorkspaceRemoteConfiguration] = [:]

#if DEBUG
    private func debugElapsedMs(since start: TimeInterval) -> String {
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return String(format: "%.2f", ms)
    }
#endif

    func panelIdFromSurfaceId(_ surfaceId: TabID) -> UUID? {
        paneTree.panelId(forSurfaceId: surfaceId)
    }

    func markExplicitClose(surfaceId: TabID) {
        explicitUserCloseTabIds.insert(surfaceId)
        closeHistoryEligibleTabIds.insert(surfaceId)
        if let panelId = panelIdFromSurfaceId(surfaceId) {
            closeHistoryEligiblePanelIds.insert(panelId)
        }
    }

    func markCloseHistoryEligible(panelId: UUID) {
        closeHistoryEligiblePanelIds.insert(panelId)
        if let surfaceId = surfaceIdFromPanelId(panelId) {
            closeHistoryEligibleTabIds.insert(surfaceId)
        }
    }

    @discardableResult
    func requestCloseTabRecordingHistory(_ tabId: TabID, force: Bool) -> Bool {
        let panelId = panelIdFromSurfaceId(tabId)
        if let panelId {
            markCloseHistoryEligible(panelId: panelId)
        }

        return requestCloseTab(tabId, force: force)
    }

    /// Non-interactive socket/API close path; remote-tmux mirrors route to tmux
    /// before any local forced close can bypass `shouldCloseTab`.
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
              let remoteTmuxController = AppDelegate.shared?.remoteTmuxController,
              remoteTmuxController.isMirrorWindowTab(workspaceId: id, panelId: panelId)
        else {
            return .notMirrorTab
        }
        return remoteTmuxController.handleMirrorTabCloseRequested(workspaceId: id, panelId: panelId)
            ? .routed
            : .rejectedMirrorTab
    }

    func withClosedPanelHistorySuppressed(_ body: () -> Void) {
        let previous = suppressClosedPanelHistory
        suppressClosedPanelHistory = true
        defer { suppressClosedPanelHistory = previous }
        body()
    }
    func markTabCloseButtonClose(surfaceId: TabID) {
        markExplicitClose(surfaceId: surfaceId)
        tabStripCloseButtonByTabId[surfaceId] = true
    }
    func markTabStripMiddleClickClose(surfaceId: TabID) {
        markExplicitClose(surfaceId: surfaceId)
        tabStripCloseButtonByTabId[surfaceId] = false
    }
    @discardableResult
    func markRemoteTmuxWorkspaceCloseAfterWindowCloseIfNeeded(surfaceId: TabID, tabStripClose: Bool, tabCloseButton: Bool, explicitUserClose: Bool = false) -> Bool {
        let shouldClose = (explicitUserClose || tabStripClose) && shouldCloseWorkspaceOnLastSurface(for: surfaceId, tabStripClose: tabStripClose)
        let shouldKeepOpen = shouldKeepWorkspaceOpenOnLastSurface(for: surfaceId, explicitUserClose: explicitUserClose, tabStripClose: tabStripClose)
        remoteTmuxWorkspaceCloseButtonByTabId[surfaceId] = shouldClose ? Optional(tabCloseButton) : nil
        if shouldClose {
            remoteTmuxKeepWorkspaceOpenAfterSessionEnd = false
            remoteTmuxKeepWorkspaceOpenTabIds.remove(surfaceId); clearCloseHistoryEligibility(tabId: surfaceId)
        } else if shouldKeepOpen {
            remoteTmuxKeepWorkspaceOpenAfterSessionEnd = true; remoteTmuxKeepWorkspaceOpenTabIds.insert(surfaceId)
        }
        return shouldClose
    }

    func handleRemoteTmuxSessionEndedKeepingWorkspaceOpenIfNeeded() -> Bool {
        guard remoteTmuxKeepWorkspaceOpenAfterSessionEnd else { return false }
        remoteTmuxKeepWorkspaceOpenAfterSessionEnd = false; isRemoteTmuxMirror = false
        let panelIds = remoteTmuxKeepWorkspaceOpenTabIds.compactMap { panelIdFromSurfaceId($0) }
        remoteTmuxKeepWorkspaceOpenTabIds.removeAll(); remoteTmuxWindowMirrors.removeAll()
        for panelId in panelIds { _ = closePanel(panelId, force: true) }
        if panels.isEmpty { _ = createReplacementTerminalPanel() }
        return true
    }

    private func clearRemoteTmuxWorkspaceCloseIntent(tabId: TabID) {
        remoteTmuxWorkspaceCloseButtonByTabId.removeValue(forKey: tabId); remoteTmuxKeepWorkspaceOpenTabIds.remove(tabId)
        if remoteTmuxKeepWorkspaceOpenTabIds.isEmpty { remoteTmuxKeepWorkspaceOpenAfterSessionEnd = false }
    }

    private func recordRemoteTmuxWorkspaceCloseAfterWindowClose(routed: Bool, tabId: TabID, panelId: UUID, explicitUserClose: Bool, tabStripClose: Bool, tabCloseButton: Bool) {
        if routed {
            _ = markRemoteTmuxWorkspaceCloseAfterWindowCloseIfNeeded(
                surfaceId: tabId,
                tabStripClose: tabStripClose,
                tabCloseButton: tabCloseButton,
                explicitUserClose: explicitUserClose
            )
        } else {
            clearRemoteTmuxWorkspaceCloseIntent(tabId: tabId)
            clearCloseHistoryEligibility(tabId: tabId, panelId: panelId)
        }
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
        tmuxWorkspaceFlashPanelId = panelId
        tmuxWorkspaceFlashReason = reason
        tmuxWorkspaceFlashToken &+= 1
    }

    /// Folds the media-device state of every browser pane into a single
    /// workspace-level summary.
    private func currentBrowserMediaActivity(
        panels sourcePanels: [UUID: any Panel]? = nil
    ) -> BrowserMediaActivity {
        BrowserMediaActivity.aggregating(
            (sourcePanels ?? panels).values.compactMap { ($0 as? BrowserPanel)?.mediaActivity }
        )
    }

    private func setBrowserMediaActivity(
        _ activity: BrowserMediaActivity,
        invalidateSidebarObservation: Bool
    ) {
        guard browserMediaActivity != activity else { return }
        browserMediaActivity = activity
        if invalidateSidebarObservation {
            sidebarMetadata.invalidateWorkspaceObservation()
        }
    }

    private func refreshBrowserMediaActivity(invalidateSidebarObservation: Bool = true) {
        setBrowserMediaActivity(
            currentBrowserMediaActivity(),
            invalidateSidebarObservation: invalidateSidebarObservation
        )
    }

    private func handleBrowserMediaActivityChanged(_ browserPanel: BrowserPanel) {
        syncBrowserAudioPlayingStateForPanel(browserPanel.id, browserPanel: browserPanel)
        refreshBrowserMediaActivity()
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
            let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
            let faviconUpdate: Data?? = existing.iconImageData == favicon ? nil : .some(favicon)
            let loadingUpdate: Bool? = existing.isLoading == isLoading ? nil : isLoading
            let mutedUpdate: Bool? = existing.isAudioMuted == isMuted ? nil : isMuted
            guard titleUpdate != nil || faviconUpdate != nil || loadingUpdate != nil || mutedUpdate != nil else { return }
            self.bonsplitController.updateTab(
                tabId,
                title: titleUpdate,
                iconImageData: faviconUpdate,
                hasCustomTitle: self.panelCustomTitles[browserPanel.id] != nil,
                isLoading: loadingUpdate,
                isAudioMuted: mutedUpdate
            )
        }
        panelSubscriptions[browserPanel.id] = subscription
        browserPanel.onMediaActivityChanged = { [weak self, weak browserPanel] _ in
            guard let self, let browserPanel else { return }
            self.handleBrowserMediaActivityChanged(browserPanel)
        }
        handleBrowserMediaActivityChanged(browserPanel)
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

    private func syncBrowserAudioPlayingStateForPanel(_ panelId: UUID, browserPanel: BrowserPanel? = nil) {
        guard let browserPanel = browserPanel ?? self.browserPanel(for: panelId),
              let tabId = surfaceIdFromPanelId(panelId),
              let tab = bonsplitController.tab(tabId),
              tab.isAudioPlaying != browserPanel.isPlayingAudio else { return }
        bonsplitController.updateTab(tabId, isAudioPlaying: browserPanel.isPlayingAudio)
    }

    func setPreferredBrowserProfileID(_ profileID: UUID?) {
        guard let profileID else {
            preferredBrowserProfileID = nil
            return
        }
        guard BrowserProfileStore.shared.profileDefinition(id: profileID) != nil else { return }
        preferredBrowserProfileID = profileID
    }

    private func resolvedNewBrowserProfileID(
        preferredProfileID: UUID? = nil,
        sourcePanelId: UUID? = nil
    ) -> UUID {
        if let preferredProfileID,
           BrowserProfileStore.shared.profileDefinition(id: preferredProfileID) != nil {
            return preferredProfileID
        }
        if let sourcePanelId,
           let sourceBrowserPanel = browserPanel(for: sourcePanelId),
           BrowserProfileStore.shared.profileDefinition(id: sourceBrowserPanel.profileID) != nil {
            return sourceBrowserPanel.profileID
        }
        if let preferredBrowserProfileID,
           BrowserProfileStore.shared.profileDefinition(id: preferredBrowserProfileID) != nil {
            return preferredBrowserProfileID
        }
        return BrowserProfileStore.shared.effectiveLastUsedProfileID
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
                let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
                let dirtyUpdate: Bool? = existing.isDirty == isDirty ? nil : isDirty
                guard titleUpdate != nil || dirtyUpdate != nil else { return }
                self.bonsplitController.updateTab(
                    tabId,
                    title: titleUpdate,
                    hasCustomTitle: self.panelCustomTitles[markdownPanel.id] != nil,
                    isDirty: dirtyUpdate
                )
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
            let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
            let iconUpdate: String?? = existing.icon == resolvedIcon ? nil : .some(resolvedIcon)
            let dirtyUpdate: Bool? = existing.isDirty == isDirty ? nil : isDirty
            guard titleUpdate != nil || iconUpdate != nil || dirtyUpdate != nil else { return }
            self.bonsplitController.updateTab(
                tabId,
                title: titleUpdate,
                icon: iconUpdate,
                hasCustomTitle: self.panelCustomTitles[filePreviewPanel.id] != nil,
                isDirty: dirtyUpdate
            )
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
            let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
            let dirtyUpdate: Bool? = existing.isDirty == isDirty ? nil : isDirty
            guard titleUpdate != nil || dirtyUpdate != nil else { return }
            self.bonsplitController.updateTab(
                tabId,
                title: titleUpdate,
                hasCustomTitle: self.panelCustomTitles[agentPanel.id] != nil,
                isDirty: dirtyUpdate
            )
        }
        agentSessionPanelCallbackIds.insert(agentPanel.id)
    }

    func discardAgentSessionPanelSubscription(panelId: UUID, panel: (any Panel)?) {
        if let agentPanel = panel as? AgentSessionPanel {
            agentPanel.onDisplayStateChanged = nil
        }
        agentSessionPanelCallbackIds.remove(panelId)
    }

    func discardBrowserPanelSubscription(panelId _: UUID, panel: (any Panel)?) {
        guard let browserPanel = panel as? BrowserPanel else { return }
        browserPanel.onMediaActivityChanged = nil
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
        let candidates = [
            focusedPanelId.flatMap { panelDirectories[$0] },
            focusedPanelId.flatMap { terminalPanel(for: $0)?.requestedWorkingDirectory },
            currentDirectory,
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func surfaceKind(for panel: any Panel) -> String {
        switch panel.panelType {
        case .terminal:
            return SurfaceKind.terminal.rawValue
        case .browser:
            return SurfaceKind.browser.rawValue
        case .markdown:
            return SurfaceKind.markdown.rawValue
        case .filePreview:
            return SurfaceKind.filePreview.rawValue
        case .rightSidebarTool:
            return SurfaceKind.rightSidebarTool.rawValue
        case .customSidebar:
            return SurfaceKind.customSidebar.rawValue
        case .agentSession:
            return SurfaceKind.agentSession.rawValue
        case .project:
            return SurfaceKind.project.rawValue
        case .extensionBrowser:
            return SurfaceKind.extensionBrowser.rawValue
        }
    }

    private func resolvedPanelTitle(panelId: UUID, fallback: String) -> String {
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = trimmedFallback.isEmpty ? "Tab" : trimmedFallback
        if let custom = panelCustomTitles[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return fallbackTitle
    }

    private func syncPinnedStateForTab(_ tabId: TabID, panelId: UUID) {
        let isPinned = pinnedPanelIds.contains(panelId)
        let kind = panels[panelId].map { surfaceKind(for: $0) }
        if let tab = bonsplitController.tab(tabId),
           tab.isPinned == isPinned,
           kind.map({ tab.kind == $0 }) ?? true {
            return
        }
        if let kind {
            bonsplitController.updateTab(tabId, kind: .some(kind), isPinned: isPinned)
        } else {
            bonsplitController.updateTab(tabId, isPinned: isPinned)
        }
    }

    private func hasVisibleNotificationIndicator(panelId: UUID) -> Bool {
        AppDelegate.shared?.notificationStore?.hasVisibleNotificationIndicator(forTabId: id, surfaceId: panelId) ?? false
    }

    private func hasUnreadNotification(panelId: UUID) -> Bool {
        AppDelegate.shared?.notificationStore?.hasUnreadNotification(forTabId: id, surfaceId: panelId) ?? false
    }

    private func attentionPersistentState() -> WorkspaceAttentionPersistentState {
        let notificationStore = AppDelegate.shared?.notificationStore
        let unreadPanelIDs = Set(
            panels.keys.filter {
                restoredUnreadPanelIds.contains($0) ||
                    (notificationStore?.hasUnreadNotification(forTabId: id, surfaceId: $0) ?? false)
            }
        )
        return WorkspaceAttentionPersistentState(
            unreadPanelIDs: unreadPanelIDs,
            focusedReadPanelID: notificationStore?.focusedReadIndicatorSurfaceId(forTabId: id),
            manualUnreadPanelIDs: manualUnreadPanelIds
        )
    }

    private func requestAttentionFlash(panelId: UUID, reason: WorkspaceAttentionFlashReason) {
        let decision = WorkspaceAttentionCoordinator.decideFlash(
            targetPanelID: panelId,
            reason: reason,
            persistentState: attentionPersistentState()
        )
        guard decision.isAllowed else { return }
        panels[panelId]?.triggerFlash(reason: reason)
    }

    private func syncUnreadBadgeStateForPanel(_ panelId: UUID) {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        let notificationStore = AppDelegate.shared?.notificationStore
        let shouldShowUnread = Self.shouldShowUnreadIndicator(
            hasUnreadNotification: hasVisibleNotificationIndicator(panelId: panelId),
            hasPanelUnreadIndicator: manualUnreadPanelIds.contains(panelId) || restoredUnreadPanelIds.contains(panelId),
            isWorkspaceManuallyUnread: notificationStore?.hasManualUnread(forTabId: id) ?? false,
            isWorkspaceManualUnreadRepresentative: representativePanelIdForWorkspaceManualUnread() == panelId
        )
        if let existing = bonsplitController.tab(tabId), existing.showsNotificationBadge == shouldShowUnread {
            return
        }
        bonsplitController.updateTab(tabId, showsNotificationBadge: shouldShowUnread)
    }

    private func syncUnreadBadgeStateForAllPanels() {
        for panelId in panels.keys {
            syncUnreadBadgeStateForPanel(panelId)
        }
    }

    func syncPanelDerivedWorkspaceUnread() {
        AppDelegate.shared?.notificationStore?.setPanelDerivedUnread(
            !manualUnreadPanelIds.isEmpty ||
                hasWorkspaceContributingRestoredUnreadIndicator,
            forTabId: id
        )
    }

    var hasWorkspaceContributingRestoredUnreadIndicator: Bool {
        restoredUnreadPanelIndicators.values.contains { $0.contributesToWorkspaceUnread }
    }

    private func normalizePinnedTabs(in paneId: PaneID) {
        guard !isNormalizingPinnedTabOrder else { return }
        isNormalizingPinnedTabOrder = true
        defer { isNormalizingPinnedTabOrder = false }

        let tabs = bonsplitController.tabs(inPane: paneId)
        let pinnedTabs = tabs.filter { tab in
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return false }
            return pinnedPanelIds.contains(panelId)
        }
        let unpinnedTabs = tabs.filter { tab in
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return true }
            return !pinnedPanelIds.contains(panelId)
        }
        let desiredOrder = pinnedTabs + unpinnedTabs

        for (index, desiredTab) in desiredOrder.enumerated() {
            let currentTabs = bonsplitController.tabs(inPane: paneId)
            guard let currentIndex = currentTabs.firstIndex(where: { $0.id == desiredTab.id }) else { continue }
            if currentIndex != index {
                _ = bonsplitController.reorderTab(desiredTab.id, toIndex: index)
            }
        }
    }

    private func insertionIndexToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> Int {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let anchorIndex = tabs.firstIndex(where: { $0.id == anchorTabId }) else { return tabs.count }
        let pinnedCount = tabs.reduce(into: 0) { count, tab in
            if let panelId = panelIdFromSurfaceId(tab.id), pinnedPanelIds.contains(panelId) {
                count += 1
            }
        }
        let rawTarget = min(anchorIndex + 1, tabs.count)
        return max(rawTarget, pinnedCount)
    }

    /// Sets, replaces, or clears (empty/nil `title`) a panel custom title.
    ///
    /// `.auto` writes are rejected when a user-set title exists, and `.auto`
    /// never clears. Returns whether the write landed.
    @discardableResult
    func setPanelCustomTitle(panelId: UUID, title: String?, source: CustomTitleSource = .user) -> Bool {
        guard panels[panelId] != nil else { return false }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previous = panelCustomTitles[panelId]
        if source == .auto {
            guard !trimmed.isEmpty else { return false }
            if previous != nil, (panelCustomTitleSources[panelId] ?? .user) == .user { return false }
        }
        if trimmed.isEmpty {
            guard previous != nil else { return false }
            panelCustomTitles.removeValue(forKey: panelId)
            panelCustomTitleSources.removeValue(forKey: panelId)
        } else {
            guard previous != trimmed else {
                // Same text: a user write still claims ownership so a later
                // auto write cannot replace a title the user re-confirmed.
                if source == .user { panelCustomTitleSources[panelId] = .user }
                return true
            }
            panelCustomTitles[panelId] = trimmed
            panelCustomTitleSources[panelId] = source
        }

        guard let panel = panels[panelId], let tabId = surfaceIdFromPanelId(panelId) else { return true }
        let baseTitle = panelTitles[panelId] ?? panel.displayTitle
        bonsplitController.updateTab(
            tabId,
            title: resolvedPanelTitle(panelId: panelId, fallback: baseTitle),
            hasCustomTitle: panelCustomTitles[panelId] != nil
        )
        // A remote tmux mirror tab rename propagates to `rename-window`.
        if isRemoteTmuxMirror {
            AppDelegate.shared?.remoteTmuxController.handleMirrorWindowRenamed(
                workspaceId: id, panelId: panelId, title: trimmed
            )
        }
        return true
    }

    func isPanelPinned(_ panelId: UUID) -> Bool {
        pinnedPanelIds.contains(panelId)
    }

    func panelKind(panelId: UUID) -> String? {
        guard let panel = panels[panelId] else { return nil }
        return surfaceKind(for: panel)
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
            pendingTerminalInputObserversByPanelId[panel.id]?.isEmpty == false
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
        guard let panel = panels[panelId] else { return nil }
        let fallback = panelTitles[panelId] ?? panel.displayTitle
        return resolvedPanelTitle(panelId: panelId, fallback: fallback)
    }

    func setPanelPinned(panelId: UUID, pinned: Bool) {
        guard panels[panelId] != nil else { return }
        let wasPinned = pinnedPanelIds.contains(panelId)
        guard wasPinned != pinned else { return }
        if pinned {
            pinnedPanelIds.insert(panelId)
        } else {
            pinnedPanelIds.remove(panelId)
        }

        guard let tabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId) else { return }
        bonsplitController.updateTab(tabId, isPinned: pinned)
        normalizePinnedTabs(in: paneId)
    }

    func markPanelUnread(_ panelId: UUID) {
        guard panels[panelId] != nil else { return }
        let didClearRestored = restoredUnreadPanelIndicators.removeValue(forKey: panelId) != nil
        let didInsertManual = manualUnreadPanelIds.insert(panelId).inserted
        guard didInsertManual || didClearRestored else { return }
        manualUnreadMarkedAt[panelId] = Date()
        syncUnreadBadgeStateForPanel(panelId)
    }

    func preferredUnreadPanelIdForJump() -> UUID? {
        let latestManualPanelId = manualUnreadMarkedAt
            .filter { manualUnreadPanelIds.contains($0.key) && panels[$0.key] != nil }
            .max { $0.value < $1.value }?
            .key
        if let latestManualPanelId {
            return latestManualPanelId
        }
        if let manualPanelId = manualUnreadPanelIds.first(where: { panels[$0] != nil }) {
            return manualPanelId
        }
        if let restoredPanelId = restoredUnreadPanelIds.first(where: { panels[$0] != nil }) {
            return restoredPanelId
        }
        return representativePanelIdForWorkspaceManualUnread()
    }

    func markPanelRead(_ panelId: UUID) {
        guard panels[panelId] != nil else { return }
        let notificationStore = AppDelegate.shared?.notificationStore
        notificationStore?.markRead(forTabId: id, surfaceId: panelId)
        _ = clearManualUnreadState(panelId: panelId)
        let restoredIndicator = restoredUnreadPanelIndicators[panelId]
        let didClearRestored = clearRestoredUnreadIndicatorState(panelId: panelId)
        if didClearRestored,
           restoredIndicator?.contributesToWorkspaceUnread == true,
           !hasWorkspaceContributingRestoredUnreadIndicator {
            _ = notificationStore?.clearRestoredUnreadIndicator(forTabId: id)
        }
        syncUnreadBadgeStateForPanel(panelId)
    }

    func clearUnreadAfterJump(panelId: UUID?) {
        if let panelId,
           manualUnreadPanelIds.contains(panelId) || restoredUnreadPanelIds.contains(panelId) {
            markPanelRead(panelId)
            return
        }
        AppDelegate.shared?.notificationStore?.markRead(forTabId: id)
    }

    func clearManualUnread(panelId: UUID) {
        let didRemoveManual = clearManualUnreadState(panelId: panelId)
        let didRemoveRestored = clearRestoredUnreadIndicatorState(panelId: panelId)
        guard didRemoveManual || didRemoveRestored else { return }
        syncUnreadBadgeStateForPanel(panelId)
    }

    @discardableResult
    func clearAllPanelUnreadIndicatorsForWorkspaceRead() -> Bool {
        let hadLocalUnreadIndicators = !manualUnreadPanelIds.isEmpty || !restoredUnreadPanelIds.isEmpty
        let affectedPanelIds = Set(panels.keys)
            .union(manualUnreadPanelIds)
            .union(restoredUnreadPanelIds)
        guard !affectedPanelIds.isEmpty else { return false }
        manualUnreadPanelIds.removeAll()
        restoredUnreadPanelIndicators.removeAll()
        manualUnreadMarkedAt.removeAll()
        for panelId in affectedPanelIds {
            syncUnreadBadgeStateForPanel(panelId)
        }
        return hadLocalUnreadIndicators
    }

    private func clearManualUnreadState(panelId: UUID) -> Bool {
        let didRemoveUnread = manualUnreadPanelIds.remove(panelId) != nil
        manualUnreadMarkedAt.removeValue(forKey: panelId)
        return didRemoveUnread
    }

    func restorePanelUnreadIndicator(
        _ panelId: UUID,
        contributesToWorkspaceUnread: Bool = true
    ) {
        guard panels[panelId] != nil else { return }
        let nextIndicator = RestoredPanelUnreadIndicator(
            contributesToWorkspaceUnread: contributesToWorkspaceUnread
        )
        guard restoredUnreadPanelIndicators[panelId] != nextIndicator else { return }
        restoredUnreadPanelIndicators[panelId] = nextIndicator
        syncUnreadBadgeStateForPanel(panelId)
    }

    func clearRestoredUnreadIndicator(panelId: UUID) {
        let didRemoveUnread = clearRestoredUnreadIndicatorState(panelId: panelId)
        guard didRemoveUnread else { return }
        syncUnreadBadgeStateForPanel(panelId)
    }

    func hasRestoredUnreadIndicator(panelId: UUID) -> Bool {
        restoredUnreadPanelIds.contains(panelId)
    }

    func restoredUnreadIndicatorContributesToWorkspace(panelId: UUID) -> Bool? {
        restoredUnreadPanelIndicators[panelId]?.contributesToWorkspaceUnread
    }

    private func clearRestoredUnreadIndicatorState(panelId: UUID) -> Bool {
        restoredUnreadPanelIndicators.removeValue(forKey: panelId) != nil
    }

    static func shouldShowUnreadIndicator(
        hasUnreadNotification: Bool,
        hasPanelUnreadIndicator: Bool,
        isWorkspaceManuallyUnread: Bool = false,
        isWorkspaceManualUnreadRepresentative: Bool = false
    ) -> Bool {
        hasUnreadNotification ||
            hasPanelUnreadIndicator ||
            (isWorkspaceManuallyUnread && isWorkspaceManualUnreadRepresentative)
    }

    // MARK: - Title Management

    /// Who set a custom title. Auto-naming (AI-generated titles) must never
    /// overwrite a user-set title; this enum carries that distinction for
    /// workspace and panel custom titles, and round-trips through session
    /// persistence.
    enum CustomTitleSource: String, Codable, Sendable {
        case user
        case auto
    }

    var hasCustomTitle: Bool {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }

    /// The provenance of the current custom title, normalizing legacy state:
    /// `nil` when no custom title is set; `.user` when a title exists but
    /// provenance was never recorded (pre-provenance snapshots, carried moves).
    var effectiveCustomTitleSource: CustomTitleSource? {
        hasCustomTitle ? (customTitleSource ?? .user) : nil
    }

    var hasCustomDescription: Bool {
        Self.normalizedCustomDescription(customDescription) != nil
    }

    func applyProcessTitle(_ title: String) {
        if processTitle != title {
            processTitle = title
        }
        guard customTitle == nil else { return }
        guard self.title != title else { return }
#if DEBUG
        cmuxDebugLog(
            "workspace.title.applyProcess workspace=\(id.uuidString.prefix(5)) " +
            "from=\"\(debugWorkspaceDescriptionPreview(self.title, limit: 80))\" " +
            "to=\"\(debugWorkspaceDescriptionPreview(title, limit: 80))\""
        )
#endif
        self.title = title
    }

    func setCustomColor(_ hex: String?) {
        if let hex {
            customColor = WorkspaceTabColorSettings.normalizedHex(hex)
        } else {
            customColor = nil
        }
    }

    func setTerminalScrollBarHidden(_ hidden: Bool) {
        guard terminalScrollBarHidden != hidden else { return }
        terminalScrollBarHidden = hidden
        NotificationCenter.default.post(
            name: Self.terminalScrollBarHiddenDidChangeNotification,
            object: self
        )
    }

    private static func normalizedCustomDescription(_ description: String?) -> String? {
        let normalizedLineEndings = description?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalizedLineEndings?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return normalizedLineEndings
    }

    /// Sets, replaces, or clears (empty/nil `title`) the workspace custom title.
    ///
    /// `.auto` writes are rejected when a user-set title exists, and `.auto`
    /// never clears. Returns whether the write landed.
    @discardableResult
    func setCustomTitle(_ title: String?, source: CustomTitleSource = .user) -> Bool {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if source == .auto {
            guard !trimmed.isEmpty else { return false }
            if hasCustomTitle, (customTitleSource ?? .user) == .user { return false }
        }
        if trimmed.isEmpty {
            customTitle = nil
            customTitleSource = nil
            self.title = processTitle
        } else {
            customTitle = trimmed
            customTitleSource = source
            self.title = trimmed
        }
        return true
    }

    func setCustomDescription(_ description: String?) {
        let normalizedDescription = Self.normalizedCustomDescription(description)
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
            "input=\"\(debugWorkspaceDescriptionPreview(description))\" " +
            "normalized=\"\(debugWorkspaceDescriptionPreview(normalizedDescription))\""
        )
#endif
        customDescription = normalizedDescription
    }

    // MARK: - Directory Updates

    private enum PanelDirectoryUpdateSource {
        case liveReport
        case restoredSnapshotMetadata
    }

    private static func unmountedVolumeRoot(
        for workingDirectory: String,
        fileManager: FileManager = .default
    ) -> String? {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let components = URL(fileURLWithPath: trimmed, isDirectory: true)
            .standardizedFileURL
            .pathComponents
        guard components.count >= 3,
              components[0] == "/",
              components[1] == "Volumes",
              !components[2].isEmpty else {
            return nil
        }

        let volumeRoot = "/Volumes/\(components[2])"
        return fileManager.fileExists(atPath: volumeRoot) ? nil : volumeRoot
    }

    private func configTrackingDirectory(for panelId: UUID?) -> String? {
        // Remote workspace directories are remote-host paths; no local per-directory config can apply.
        if isRemoteWorkspace { return nil }
        if let panelId {
            for candidate in [panelDirectories[panelId], terminalPanel(for: panelId)?.requestedWorkingDirectory] {
                let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !trimmed.isEmpty { return trimmed }
            }
        }
        let trimmedCurrentDirectory = currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedCurrentDirectory.isEmpty ? nil : trimmedCurrentDirectory
    }

    @discardableResult
    func updatePanelDirectory(panelId: UUID, directory: String) -> Bool { updatePanelDirectory(panelId: panelId, directory: directory, source: .liveReport) }

    @discardableResult
    private func updatePanelDirectory(panelId: UUID, directory: String, source: PanelDirectoryUpdateSource) -> Bool {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if source == .liveReport,
           shouldIgnoreRestoredGuardedDirectoryReport(panelId: panelId, reportedDirectory: trimmed) {
            return false
        }
        if panelDirectories[panelId] != trimmed { panelDirectories[panelId] = trimmed }
        if panelId == focusedPanelId {
            let nextSurfaceTabBarDirectory = configTrackingDirectory(for: panelId)
            if surfaceTabBarDirectory != nextSurfaceTabBarDirectory { surfaceTabBarDirectory = nextSurfaceTabBarDirectory }
            if currentDirectory != trimmed { currentDirectory = trimmed }
        }
        return true
    }

    private func shouldIgnoreRestoredGuardedDirectoryReport(
        panelId: UUID,
        reportedDirectory: String
    ) -> Bool {
        guard let restoredDirectory = restoredGuardedWorkingDirectoriesByPanelId[panelId] else { return false }

        if reportedDirectory == restoredDirectory {
            // The resumed shell confirmed the restored directory; stop guarding.
            restoredGuardedWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
            return false
        }

        if Self.unmountedVolumeRoot(for: restoredDirectory) != nil {
            // Keep guarding until the restored volume remounts and reports its cwd (#5278).
#if DEBUG
            cmuxDebugLog(
                "session.restore.cwdReport.ignored panel=\(panelId.uuidString.prefix(5)) " +
                "saved=\(restoredDirectory) reported=\(reportedDirectory)"
            )
#endif
            return true
        }

        // Ignore the first fallback cwd only if the restored directory still exists (#6617).
        restoredGuardedWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
        var restoredDirectoryIsDirectory: ObjCBool = false
        let restoredDirectoryStillExists = FileManager.default.fileExists(atPath: restoredDirectory, isDirectory: &restoredDirectoryIsDirectory) && restoredDirectoryIsDirectory.boolValue
#if DEBUG
        cmuxDebugLog(
            "session.restore.cwdReport.\(restoredDirectoryStillExists ? "ignoredOnce" : "accepted") " +
            "panel=\(panelId.uuidString.prefix(5)) saved=\(restoredDirectory) reported=\(reportedDirectory)"
        )
#endif
        return restoredDirectoryStillExists
    }

    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {
        guard panels[panelId] != nil else { return }
        let previousState = panelShellActivityStates[panelId] ?? .unknown
        guard previousState != state else { return }
        panelShellActivityStates[panelId] = state
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

    func setAgentLifecycle(
        key: String,
        panelId: UUID?,
        lifecycle: AgentHibernationLifecycleState
    ) {
        let targetPanelId = panelId ?? focusedPanelId
        guard let targetPanelId, panels[targetPanelId] != nil else { return }
        agentLifecycleStatesByPanelId[targetPanelId, default: [:]][key] = lifecycle
        recordAgentLifecycleChange(panelId: targetPanelId)
    }

    @discardableResult
    func clearAgentLifecycle(key: String, panelId: UUID? = nil) -> Bool {
        var didClear = false
        let panelIds = panelId.map { [$0] } ?? Array(agentLifecycleStatesByPanelId.keys)
        for panelId in panelIds {
            guard agentLifecycleStatesByPanelId[panelId]?[key] != nil else { continue }
            agentLifecycleStatesByPanelId[panelId]?.removeValue(forKey: key)
            if agentLifecycleStatesByPanelId[panelId]?.isEmpty == true {
                agentLifecycleStatesByPanelId.removeValue(forKey: panelId)
            }
            didClear = true
            recordAgentLifecycleChange(panelId: panelId)
        }
        return didClear
    }

    func clearAgentLifecycleStates(panelId: UUID) {
        guard agentLifecycleStatesByPanelId.removeValue(forKey: panelId) != nil else { return }
        recordAgentLifecycleChange(panelId: panelId)
    }

    func clearAllAgentLifecycleStates() {
        let panelIds = Array(agentLifecycleStatesByPanelId.keys)
        guard !panelIds.isEmpty else { return }
        agentLifecycleStatesByPanelId.removeAll()
        for panelId in panelIds {
            recordAgentLifecycleChange(panelId: panelId)
        }
    }

    private func recordAgentLifecycleChange(panelId: UUID) {
        AgentHibernationController.shared.recordAgentLifecycleChange(
            workspaceId: id,
            panelId: panelId
        )
    }

    func agentHibernationLifecycleState(
        panelId: UUID,
        fallback: AgentHibernationLifecycleState?
    ) -> AgentHibernationLifecycleState {
        guard let panelStates = agentLifecycleStatesByPanelId[panelId],
              !panelStates.isEmpty else {
            return fallback ?? .unknown
        }
        let states = Array(panelStates.values)
        if states.contains(.running) { return .running }
        if states.contains(.needsInput) { return .needsInput }
        if states.contains(.unknown) { return .unknown }
        if states.contains(.idle) { return .idle }
        return fallback ?? .unknown
    }

    func restorableAgentForHibernation(
        panelId: UUID,
        index: RestorableAgentSessionIndex
    ) -> SessionRestorableAgentSnapshot? {
        guard let snapshot = restoredAgentSnapshotsByPanelId[panelId] ?? index.snapshot(workspaceId: id, panelId: panelId),
              snapshot.resumeCommand != nil else {
            return nil
        }
        let fingerprint = TabManager.restorableAgentSnapshotFingerprint(snapshot)
        guard invalidatedRestoredAgentFingerprintsByPanelId[panelId] != fingerprint else {
            return nil
        }
        return snapshot
    }

    func enterAgentHibernation(
        panelId: UUID,
        agent: SessionRestorableAgentSnapshot,
        lastActivityAt: Date
    ) {
        guard let terminalPanel = panels[panelId] as? TerminalPanel,
              !terminalPanel.isAgentHibernated else {
            return
        }
        guard agent.resumeCommand != nil else { return }
        restoredAgentSnapshotsByPanelId[panelId] = agent
        restoredAgentResumeStatesByPanelId[panelId] = .manualResumeAvailable
        invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
        let keys = agentPIDKeysByPanelId[panelId] ?? []
        for key in keys {
            _ = clearAgentPID(key: key, panelId: panelId, clearStatus: false, refreshPorts: false)
        }
        if !keys.isEmpty {
            refreshTrackedAgentPorts()
        }
        terminalPanel.enterAgentHibernation(agent: agent, lastActivityAt: lastActivityAt)
    }

    @discardableResult
    func resumeAgentHibernation(panelId: UUID, focus: Bool) -> Bool {
        guard let terminalPanel = panels[panelId] as? TerminalPanel,
              terminalPanel.isAgentHibernated else {
            return false
        }
        let preparation = terminalPanel.prepareAgentHibernationResume()
        guard preparation.didResume else {
            return false
        }
        if restoredAgentSnapshotsByPanelId[panelId] != nil {
            restoredAgentResumeStatesByPanelId[panelId] = preparation.queuedStartupInput
                ? .awaitingAutoResumeCommand
                : .manualResumeAvailable
            invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
        }
        clearAgentLifecycleStates(panelId: panelId)
        AgentHibernationController.shared.recordTerminalFocus(workspaceId: id, panelId: panelId)
        if focus {
            focusPanel(panelId)
        }
        return true
    }

    @discardableResult
    func resumeVisibleAgentHibernationPanels(panelIds: Set<UUID>) -> Bool {
        var didResume = false
        for panelId in panelIds {
            guard let terminalPanel = panels[panelId] as? TerminalPanel,
                  terminalPanel.isAgentHibernated else {
                continue
            }
            didResume = resumeAgentHibernation(panelId: panelId, focus: false) || didResume
        }
        return didResume
    }

    private func restoredAgentResumeStateForAcceptedSnapshot(panelId: UUID) -> RestoredAgentResumeState {
        panelShellActivityStates[panelId] == .commandRunning
            ? .observedAgentCommandRunning
            : .manualResumeAvailable
    }

    private func updateRestoredAgentResumeState(
        panelId: UUID,
        restoredAgent: SessionRestorableAgentSnapshot,
        shellState: PanelShellActivityState
    ) {
        switch shellState {
        case .commandRunning:
            switch restoredAgentResumeStatesByPanelId[panelId] {
            case .some(.awaitingAutoResumeCommand):
                restoredAgentResumeStatesByPanelId[panelId] = .autoResumeCommandRunning
            case .some(.autoResumeCommandRunning), .some(.observedAgentCommandRunning):
                break
            case .some(.manualResumeAvailable), nil:
                invalidateRestoredAgentSnapshot(panelId: panelId, restoredAgent: restoredAgent)
            }
        case .promptIdle:
            switch restoredAgentResumeStatesByPanelId[panelId] {
            case .some(.autoResumeCommandRunning), .some(.observedAgentCommandRunning):
                invalidateRestoredAgentSnapshot(panelId: panelId, restoredAgent: restoredAgent)
            case .some(.awaitingAutoResumeCommand), .some(.manualResumeAvailable), nil:
                break
            }
        case .unknown:
            break
        }
    }

    private func invalidateRestoredAgentSnapshot(
        panelId: UUID,
        restoredAgent: SessionRestorableAgentSnapshot
    ) {
        let fingerprint = TabManager.restorableAgentSnapshotFingerprint(restoredAgent)
        invalidatedRestoredAgentFingerprintsByPanelId[panelId] = fingerprint
        clearRestoredAgentResumeBinding(panelId: panelId, restoredAgent: restoredAgent)
        clearRestoredAgentSnapshot(panelId: panelId)
#if DEBUG
        cmuxDebugLog(
            "session.restore.agent.invalidate panel=\(panelId.uuidString.prefix(5)) " +
            "kind=\(restoredAgent.kind.rawValue) session=\(restoredAgent.sessionId.prefix(8))"
        )
#endif
    }

    private func clearRestoredAgentSnapshot(panelId: UUID) {
        restoredAgentSnapshotsByPanelId.removeValue(forKey: panelId)
        restoredAgentResumeStatesByPanelId.removeValue(forKey: panelId)
    }

    private func clearRestoredAgentResumeBinding(
        panelId: UUID,
        restoredAgent: SessionRestorableAgentSnapshot
    ) {
        guard let binding = surfaceResumeBindingsByPanelId[panelId],
              binding.source == "agent-hook" else {
            return
        }
        let checkpointId = binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard checkpointId == nil || checkpointId == restoredAgent.sessionId else {
            return
        }
        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
    }

    @discardableResult
    func setSurfaceResumeBinding(_ binding: SurfaceResumeBindingSnapshot, panelId: UUID) -> Bool {
        guard terminalPanel(for: panelId) != nil,
              let startupInput = binding.inlineStartupInput(repairPortableAgentExecutable: false),
              !startupInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        surfaceResumeBindingsByPanelId[panelId] = binding
        return true
    }

    @discardableResult
    func clearSurfaceResumeBinding(panelId: UUID) -> Bool {
        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId) != nil
    }

    func surfaceResumeBinding(panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        surfaceResumeBindingsByPanelId[panelId]
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
           let activity = AppDelegate.shared?.remoteTmuxController
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

    func updatePanelGitBranch(panelId: UUID, branch: String, isDirty: Bool) {
        let state = SidebarGitBranchState(branch: branch, isDirty: isDirty)
        let existing = panelGitBranches[panelId]
        let branchChanged = existing?.branch != nil && existing?.branch != branch
        if existing?.branch != branch || existing?.isDirty != isDirty {
            panelGitBranches[panelId] = state
        }
        if branchChanged {
            if panelPullRequests[panelId] != nil {
                panelPullRequests.removeValue(forKey: panelId)
            }
            if panelId == focusedPanelId, pullRequest != nil {
                pullRequest = nil
            }
        }
        if panelId == focusedPanelId, gitBranch != state {
            gitBranch = state
        }
    }

    func clearPanelGitBranch(panelId: UUID) {
        if panelGitBranches[panelId] != nil {
            panelGitBranches.removeValue(forKey: panelId)
        }
        if panelPullRequests[panelId] != nil {
            panelPullRequests.removeValue(forKey: panelId)
        }
        if panelId == focusedPanelId {
            if gitBranch != nil {
                gitBranch = nil
            }
            if pullRequest != nil {
                pullRequest = nil
            }
        }
    }

    func updatePanelPullRequest(
        panelId: UUID,
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String? = nil,
        isStale: Bool = false
    ) {
        let existing = panelPullRequests[panelId]
        let normalizedBranch = branch?.normalizedSidebarBranchName
        let currentPanelBranch = panelGitBranches[panelId]?.branch.normalizedSidebarBranchName
        let resolvedBranch: String? = {
            if let normalizedBranch {
                return normalizedBranch
            }
            if let currentPanelBranch {
                return currentPanelBranch
            }
            guard let existing,
                  existing.number == number,
                  existing.label == label,
                  existing.url == url,
                  existing.status == status else {
                return nil
            }
            return existing.branch
        }()
        let state = SidebarPullRequestState(
            number: number,
            label: label,
            url: url,
            status: status,
            branch: resolvedBranch,
            isStale: isStale
        )
        if existing != state {
            panelPullRequests[panelId] = state
        }
        if panelId == focusedPanelId, pullRequest != state {
            pullRequest = state
        }
    }

    func clearPanelPullRequest(panelId: UUID) {
        if panelPullRequests[panelId] != nil {
            panelPullRequests.removeValue(forKey: panelId)
        }
        if panelId == focusedPanelId, pullRequest != nil {
            pullRequest = nil
        }
    }

    func clearSidebarPullRequestMetadata() {
        if !panelPullRequests.isEmpty {
            panelPullRequests.removeAll()
        }
        if pullRequest != nil {
            pullRequest = nil
        }
    }

    func clearSidebarGitMetadata() {
        if !panelGitBranches.isEmpty {
            panelGitBranches.removeAll()
        }
        clearSidebarPullRequestMetadata()
        if gitBranch != nil {
            gitBranch = nil
        }
    }

    func resetSidebarContext(reason: String = "unspecified") {
        statusEntries.removeAll()
        agentPIDs.removeAll()
        agentPIDPanelIdsByKey.removeAll()
        agentPIDKeysByPanelId.removeAll()
        clearAllAgentLifecycleStates()
        agentListeningPorts.removeAll()
        latestConversationMessage = nil
        latestSubmittedMessage = nil
        latestSubmittedAt = nil
        logEntries.removeAll()
        progress = nil
        gitBranch = nil
        panelGitBranches.removeAll()
        pullRequest = nil
        panelPullRequests.removeAll()
        surfaceListeningPorts.removeAll()
        listeningPorts.removeAll()
        metadataBlocks.removeAll()
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
    func discardHiddenBrowserWebViewsForSystemMemoryPressure(now: Date = Date()) -> Int {
        var discardedCount = 0
        for browserPanel in panels.values.compactMap({ $0 as? BrowserPanel }) {
            if browserPanel.discardHiddenWebViewForSystemMemoryPressure(now: now) {
                discardedCount += 1
            }
        }
        return discardedCount
    }

    @discardableResult
    func updatePanelTitle(panelId: UUID, title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, panels[panelId] != nil else { return false }
        var didMutate = false
        var didMutatePanelTitle = false
        var didMutateWorkspaceTitle = false

        if panelTitles[panelId] != trimmed {
            panelTitles[panelId] = trimmed
            didMutate = true
            didMutatePanelTitle = true
        }

        // Update bonsplit tab title only when this panel's title changed.
        if didMutate,
           let tabId = surfaceIdFromPanelId(panelId),
           let panel = panels[panelId] {
            let baseTitle = panelTitles[panelId] ?? panel.displayTitle
            let resolvedTitle = resolvedPanelTitle(panelId: panelId, fallback: baseTitle)
            bonsplitController.updateTab(
                tabId,
                title: resolvedTitle,
                hasCustomTitle: panelCustomTitles[panelId] != nil
            )
        }

        // If this is the only panel and no custom title, update workspace title
        if panels.count == 1, customTitle == nil {
            if self.title != trimmed {
                self.title = trimmed
                didMutate = true
                didMutateWorkspaceTitle = true
            }
            if processTitle != trimmed {
                processTitle = trimmed
            }
        }

#if DEBUG
        if didMutate {
            cmuxDebugLog(
                "workspace.title.updatePanel workspace=\(id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) panels=\(panels.count) custom=\(customTitle == nil ? 0 : 1) " +
                "panelChanged=\(didMutatePanelTitle ? 1 : 0) workspaceChanged=\(didMutateWorkspaceTitle ? 1 : 0) " +
                "title=\"\(debugWorkspaceDescriptionPreview(trimmed, limit: 80))\""
            )
        }
#endif
        return didMutate
    }

    func pruneSurfaceMetadata(validSurfaceIds: Set<UUID>) {
        for panelId in Array(pendingTerminalInputObserversByPanelId.keys) where !validSurfaceIds.contains(panelId) {
            removePendingTerminalInputObservers(forPanelId: panelId)
        }
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
        remotePTYSessionIDsByPanelId = remotePTYSessionIDsByPanelId.filter { validSurfaceIds.contains($0.key) }
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
        let unique = Set(surfaceListeningPorts.values.flatMap { $0 })
            .union(agentListeningPorts)
            .union(remoteDetectedPorts)
            .union(remoteForwardedPorts)
        let next = unique.sorted()
        if listeningPorts != next {
            listeningPorts = next
        }
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

    private func normalizedSidebarDirectory(_ directory: String?) -> String? {
        guard let directory else { return nil }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sidebarHomeDirectoryForCanonicalization(
        resolvedPanelDirectories: [UUID: String]
    ) -> String? {
        if isRemoteWorkspace {
            return SidebarBranchOrdering().inferredRemoteHomeDirectory(
                from: Array(resolvedPanelDirectories.values),
                fallbackDirectory: normalizedSidebarDirectory(currentDirectory)
            )
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func sidebarResolvedDirectory(for panelId: UUID) -> String? {
        if let directory = normalizedSidebarDirectory(panelDirectories[panelId]) {
            return directory
        }
        if let requestedDirectory = normalizedSidebarDirectory(
            terminalPanel(for: panelId)?.requestedWorkingDirectory
        ) {
            return requestedDirectory
        }
        guard panelId == focusedPanelId else { return nil }
        return normalizedSidebarDirectory(currentDirectory)
    }

    private func sidebarResolvedPanelDirectories(orderedPanelIds: [UUID]) -> [UUID: String] {
        var resolved: [UUID: String] = [:]
        for panelId in orderedPanelIds {
            if let directory = sidebarResolvedDirectory(for: panelId) {
                resolved[panelId] = directory
            }
        }
        return resolved
    }

    func sidebarDirectoriesInDisplayOrder(orderedPanelIds: [UUID], includeFallback: Bool = true) -> [String] {
        let resolvedDirectories = sidebarResolvedPanelDirectories(orderedPanelIds: orderedPanelIds)
        let homeDirectoryForCanonicalization = sidebarHomeDirectoryForCanonicalization(
            resolvedPanelDirectories: resolvedDirectories
        )
        var ordered: [String] = []
        var seen: Set<String> = []

        for panelId in orderedPanelIds {
            guard let directory = resolvedDirectories[panelId],
                  let key = SidebarBranchOrdering().canonicalDirectoryKey(
                      directory,
                      homeDirectoryForTildeExpansion: homeDirectoryForCanonicalization
                  ) else { continue }
            if seen.insert(key).inserted {
                ordered.append(directory)
            }
        }

        if includeFallback, ordered.isEmpty, let fallbackDirectory = normalizedSidebarDirectory(currentDirectory) {
            return [fallbackDirectory]
        }

        return ordered
    }

    func sidebarDirectoriesInDisplayOrder() -> [String] {
        sidebarDirectoriesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }
    func sidebarFinderDirectory() -> String? {
        guard !isRemoteWorkspace else { return nil }
        let panelIds = sidebarOrderedPanelIds()
        let localPanelIds = panelIds.filter {
            !remoteDetectedSurfaceIds.contains($0)
                && !isRemoteTerminalSurface($0)
                && !pendingRemoteTerminalChildExitSurfaceIds.contains($0)
        }
        return sidebarDirectoriesInDisplayOrder(orderedPanelIds: localPanelIds, includeFallback: panelIds.isEmpty || localPanelIds.count == panelIds.count).first
    }

    func sidebarGitBranchesInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarGitBranchState] {
        SidebarBranchOrdering()
            .orderedUniqueBranches(
                orderedPanelIds: orderedPanelIds,
                panelBranches: panelGitBranches,
                fallbackBranch: gitBranch
            )
            .map { SidebarGitBranchState(branch: $0.name, isDirty: $0.isDirty) }
    }

    func sidebarGitBranchesInDisplayOrder() -> [SidebarGitBranchState] {
        sidebarGitBranchesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarBranchDirectoryEntriesInDisplayOrder(
        orderedPanelIds: [UUID]
    ) -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        let resolvedDirectories = sidebarResolvedPanelDirectories(orderedPanelIds: orderedPanelIds)
        return SidebarBranchOrdering().orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: orderedPanelIds,
            panelBranches: panelGitBranches,
            panelDirectories: resolvedDirectories,
            defaultDirectory: normalizedSidebarDirectory(currentDirectory),
            homeDirectoryForTildeExpansion: sidebarHomeDirectoryForCanonicalization(
                resolvedPanelDirectories: resolvedDirectories
            ),
            fallbackBranch: gitBranch
        )
    }

    func sidebarBranchDirectoryEntriesInDisplayOrder() -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarPullRequestsInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarPullRequestState] {
        let validPanelPullRequests = panelPullRequests.filter { panelId, state in
            guard let pullRequestBranch = state.branch?.normalizedSidebarBranchName else {
                return true
            }
            return panelGitBranches[panelId]?.branch.normalizedSidebarBranchName == pullRequestBranch
        }
        return SidebarBranchOrdering().orderedUniquePullRequests(
            orderedPanelIds: orderedPanelIds,
            panelPullRequests: validPanelPullRequests,
            fallbackPullRequest: nil
        )
    }

    func sidebarPullRequestsInDisplayOrder() -> [SidebarPullRequestState] {
        sidebarPullRequestsInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarStatusEntriesInDisplayOrder() -> [SidebarStatusEntry] {
        sidebarStatusEntriesVisibleForDisplay().sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.key < rhs.key
        }
    }

    func sidebarMetadataBlocksInDisplayOrder() -> [SidebarMetadataBlock] {
        sidebarMetadata.metadataBlocksInDisplayOrder()
    }

    @discardableResult
    func recordConversationMessage(_ message: String?) -> Bool {
        guard let preview = Self.conversationMessagePreview(from: message) else { return false }
        guard latestConversationMessage != preview else { return false }
        latestConversationMessage = preview
        return true
    }

    @discardableResult
    func recordSubmittedMessage(_ message: String?) -> Bool {
        guard let preview = Self.conversationMessagePreview(from: message) else { return false }
        _ = recordConversationMessage(preview)
        latestSubmittedMessage = preview
        latestSubmittedAt = Date()
        return true
    }

    var isRemoteWorkspace: Bool {
        remoteConfiguration != nil
    }

    /// Ephemeral remote tmux mirror; excluded from cmux session restore.
    var isRemoteTmuxMirror: Bool = false

    /// Per-window multi-pane renderers, keyed by mirrored window-tab panel id.
    private(set) var remoteTmuxWindowMirrors: [UUID: RemoteTmuxWindowMirror] = [:]

    /// Multi-pane renderer for a window-tab panel.
    func remoteTmuxWindowMirror(forPanelId panelId: UUID) -> RemoteTmuxWindowMirror? {
        remoteTmuxWindowMirrors[panelId]
    }

    func setRemoteTmuxWindowMirror(_ mirror: RemoteTmuxWindowMirror?, forPanelId panelId: UUID) {
        objectWillChange.send()
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
        activeRemoteTerminalSurfaceIds.contains(panelId)
    }

    @MainActor
    func isPreservedEndedRemoteTerminalSurface(_ panelId: UUID) -> Bool {
        endedPersistentRemotePTYAttachSurfaceIds.contains(panelId)
    }

    @MainActor
    func markRemoteTerminalSessionClosingIfLast(surfaceId: UUID) {
        guard !isDetachingCloseTransaction,
              activeRemoteTerminalSurfaceIds.count == 1,
              activeRemoteTerminalSurfaceIds.contains(surfaceId) else {
            return
        }
        let relayPort: Int?
        if remoteConfiguration?.transport == .ssh {
            relayPort = remoteConfiguration?.relayPort
        } else {
            relayPort = nil
        }
        markRemoteTerminalSessionEnded(surfaceId: surfaceId, relayPort: relayPort)
    }

    @MainActor
    func shouldKeepPersistentRemoteSurfaceOpenAfterChildExit(_ panelId: UUID) -> Bool {
        guard remoteConfiguration?.preserveAfterTerminalExit == true else { return false }
        return activeRemoteTerminalSurfaceIds.contains(panelId) ||
            endedPersistentRemotePTYAttachSurfaceIds.contains(panelId)
    }

    @MainActor
    func shouldDemoteWorkspaceAfterChildExit(surfaceId: UUID) -> Bool {
        isRemoteWorkspace || pendingRemoteTerminalChildExitSurfaceIds.contains(surfaceId)
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
        guard let controller = remoteSessionController else {
            completion(.failure(RemoteDropUploadError.unavailable))
            return
        }
        // The coordinator pins the legacy contract of invoking the completion
        // on the main queue (see RemoteSessionCoordinator.uploadDroppedFiles),
        // so the non-Sendable completion never runs off the caller's main
        // thread even though the coordinator's parameter is `@Sendable`.
        nonisolated(unsafe) let completion = completion
        controller.uploadDroppedFiles(fileURLs, operation: operation) { result in
            completion(result)
        }
    }

    func syncRemotePortScanTTYs() {
        guard isRemoteWorkspace else { return }
        remoteSessionController?.updateRemotePortScanTTYs(surfaceTTYNames)
    }

    func remotePTYSessionControllerForSocketCommand() -> RemoteSessionCoordinator? {
        remoteSessionController
    }

    func kickRemotePortScan(panelId: UUID, reason: PortScanKickReason = .command) {
        guard isRemoteWorkspace else { return }
        syncRemotePortScanTTYs()
        remoteSessionController?.kickRemotePortScan(panelId: panelId, reason: reason)
    }

    /// Whether remote listening-port discovery may run, derived from the global
    /// sidebar ports-visibility settings. Mirrors the sidebar's own precedence
    /// (`sidebar.hideAllDetails` wins over `sidebar.showPorts`, see
    /// `SidebarWorkspaceAuxiliaryDetailVisibility.resolved`): when the ports
    /// detail is not displayed there is nothing for the remote scans to
    /// populate, so the backend ssh port-scan loop is suspended (issue #6123).
    static func remotePortScanningEnabledFromSettings(defaults: UserDefaults = .standard) -> Bool {
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        let showsPorts = settings.value(for: catalog.sidebar.showPorts)
        let hidesAllDetails = settings.value(for: catalog.sidebar.hideAllDetails)
        return showsPorts && !hidesAllDetails
    }

    /// Pushes the current remote port-scanning enablement to this workspace's
    /// active remote session, if any. No-op for non-remote workspaces.
    func applyRemotePortScanningEnabled(_ enabled: Bool) {
        remoteSessionController?.updateRemotePortScanningEnabled(enabled)
    }

    func listRemotePTYSessions() throws -> [[String: Any]] {
        guard let controller = remoteSessionController else {
            throw NSError(domain: "cmux.remote.pty", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        return try controller.listPTYSessions()
    }

    func closeRemotePTYSession(sessionID: String) throws {
        guard let controller = remoteSessionController else {
            throw NSError(domain: "cmux.remote.pty", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        try controller.closePTYSession(sessionID: sessionID)
    }

    func startRemotePTYBridge(
        sessionID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool
    ) throws -> RemotePTYBridgeServer.Endpoint {
        guard let controller = remoteSessionController else {
            throw NSError(domain: "cmux.remote.pty", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        return try controller.startPTYBridge(
            sessionID: sessionID,
            attachmentID: attachmentID,
            command: command,
            requireExisting: requireExisting
        )
    }

    func resizeRemotePTY(sessionID: String, attachmentID: String, attachmentToken: String, cols: Int, rows: Int) throws {
        guard let controller = remoteSessionController else {
            throw NSError(domain: "cmux.remote.pty", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        try controller.resizePTY(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken,
            cols: cols,
            rows: rows
        )
    }

    func detachRemotePTYAttachment(sessionID: String, attachmentID: String, attachmentToken: String) throws {
        guard let controller = remoteSessionController else {
            throw NSError(domain: "cmux.remote.pty", code: 14, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        try controller.detachPTYSession(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken
        )
    }

    func remoteStatusPayload() -> [String: Any] {
        let heartbeatAgeSeconds: Any = {
            guard let last = remoteLastHeartbeatAt else { return NSNull() }
            return max(0, Date().timeIntervalSince(last))
        }()
        let heartbeatTimestamp: Any = {
            guard let last = remoteLastHeartbeatAt else { return NSNull() }
            return Self.remoteHeartbeatDateFormatter.string(from: last)
        }()
        var payload: [String: Any] = [
            "enabled": remoteConfiguration != nil,
            "state": remoteConnectionState.rawValue,
            "connected": remoteConnectionState == .connected,
            "active_terminal_sessions": activeRemoteTerminalSessionCount,
            "daemon": remoteDaemonStatus.payload(),
            "detected_ports": remoteDetectedPorts,
            "forwarded_ports": remoteForwardedPorts,
            "conflicted_ports": remotePortConflicts,
            "detail": remoteConnectionDetail ?? NSNull(),
            "heartbeat": [
                "count": remoteHeartbeatCount,
                "last_seen_at": heartbeatTimestamp,
                "age_seconds": heartbeatAgeSeconds,
            ],
        ]
        if let endpoint = remoteProxyEndpoint {
            payload["proxy"] = [
                "state": "ready",
                "host": endpoint.host,
                "port": endpoint.port,
                "schemes": ["socks5", "http_connect"],
                "url": "socks5://\(endpoint.host):\(endpoint.port)",
            ]
        } else {
            let proxyState: String
            if hasProxyOnlyRemoteSidebarError {
                proxyState = "error"
            } else {
                switch remoteConnectionState {
                case .connecting, .reconnecting:
                    proxyState = "connecting"
                case .error:
                    proxyState = "error"
                default:
                    proxyState = "unavailable"
                }
            }
            payload["proxy"] = [
                "state": proxyState,
                "host": NSNull(),
                "port": NSNull(),
                "schemes": ["socks5", "http_connect"],
                "url": NSNull(),
                "error_code": proxyState == "error" ? "proxy_unavailable" : NSNull(),
            ]
        }
        if let remoteConfiguration {
            payload["transport"] = remoteConfiguration.transport.rawValue
            payload["destination"] = remoteConfiguration.destination
            payload["port"] = remoteConfiguration.port ?? NSNull()
            payload["has_identity_file"] = remoteConfiguration.identityFile != nil
            payload["has_ssh_options"] = !remoteConfiguration.sshOptions.isEmpty
            payload["local_proxy_port"] = remoteConfiguration.localProxyPort ?? NSNull()
            payload["persistent_daemon_slot"] = remoteConfiguration.persistentDaemonSlot ?? NSNull()
        } else {
            payload["transport"] = NSNull()
            payload["destination"] = NSNull()
            payload["port"] = NSNull()
            payload["has_identity_file"] = false
            payload["has_ssh_options"] = false
            payload["local_proxy_port"] = NSNull()
            payload["persistent_daemon_slot"] = NSNull()
        }
        return payload
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
            remotePTYSessionIDsByPanelId.removeAll()
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
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        pendingRemoteSurfacePWD = nil
        pendingRemoteSurfacePWDSurfaceId = nil
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
            remotePTYSessionIDsByPanelId.removeAll()
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
           normalizedRemotePTYSessionID(remotePTYSessionIDsByPanelId[panelId]) == nil {
            remotePTYSessionIDsByPanelId[panelId] = Self.defaultSSHPTYSessionID(workspaceId: id, panelId: panelId)
        }
        guard activeRemoteTerminalSurfaceIds.insert(panelId).inserted else { return }
        activeRemoteTerminalSessionCount = activeRemoteTerminalSurfaceIds.count
        _ = applyPendingRemoteSurfacePWDIfNeeded(to: panelId)
        applyPendingRemoteSurfaceTTYIfNeeded(to: panelId)
        _ = applyPendingRemoteSurfacePortKickIfNeeded(to: panelId)
    }

    func untrackRemoteTerminalSurface(_ panelId: UUID) {
        guard activeRemoteTerminalSurfaceIds.remove(panelId) != nil else { return }
        activeRemoteTerminalSessionCount = activeRemoteTerminalSurfaceIds.count
        guard !isDetachingCloseTransaction else { return }
        maybeDemoteRemoteWorkspaceAfterSSHSessionEnded()
    }

    /// Normalizes a user-supplied workspace environment: trims keys and drops any
    /// entry with a blank key or blank value. Dropping blank values keeps behavior
    /// identical across the `additionalEnvironment` channel (which already skips
    /// empty values) and the `initialEnvironmentOverrides` channel (which would
    /// otherwise export a blank value on the initial shell only).
    ///
    /// Reserved `CMUX_*` variables are intentionally *not* stripped by name — they
    /// are protected at spawn time by `mergedStartupEnvironment(protectedKeys:)`,
    /// the single authority on which keys are managed. That protection is an exact
    /// Swift-string match, but the env eventually crosses the Swift→C boundary
    /// (`strdup` / Ghostty), where a key is truncated at its first NUL. A key like
    /// `"CMUX_SOCKET_PATH\0x"` would dodge the exact-match check yet collapse to
    /// `CMUX_SOCKET_PATH` in the spawned shell, so reject any key containing a NUL
    /// (and `=`, which is never a valid env var name) and any value containing a
    /// NUL. This is the single choke point for every entry point (CLI, cmux.json,
    /// session restore), so the guard cannot be bypassed.
    // `nonisolated` so the nonisolated socket workspace-create parsing path
    // (`v2WorkspaceCreate`) can call this pure helper without hopping to the main
    // actor; `Workspace` is `@MainActor`, so its statics are main-actor-isolated by
    // default.
    nonisolated static func sanitizedWorkspaceEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.reduce(into: [String: String]()) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty,
                  !pair.value.isEmpty,
                  !key.contains("\0"),
                  !key.contains("="),
                  !pair.value.contains("\0") else { return }
            result[key] = pair.value
        }
    }

    /// Pure merge core: overlays `explicit` on top of `workspaceEnvironment`.
    /// Managed `CMUX_*` / terminal-identity keys are protected downstream by
    /// `mergedStartupEnvironment(protectedKeys:)`; this only decides precedence
    /// among user-supplied values — explicit per-surface entries (layout `env`,
    /// scrollback replay, SSH startup) win over the workspace set. Static so the
    /// `init` path can call it before `self` is fully initialized.
    static func startupEnvironment(
        workspaceEnvironment: [String: String],
        overlaying explicit: [String: String]
    ) -> [String: String] {
        guard !workspaceEnvironment.isEmpty else { return explicit }
        var merged = workspaceEnvironment
        for (key, value) in explicit {
            merged[key] = value
        }
        return merged
    }

    /// Instance convenience over ``startupEnvironment(workspaceEnvironment:overlaying:)``
    /// for the post-init surface-creation paths.
    func startupEnvironmentMergingWorkspaceEnvironment(_ explicit: [String: String]) -> [String: String] {
        Self.startupEnvironment(workspaceEnvironment: workspaceEnvironment, overlaying: explicit)
    }

    private func terminalStartupEnvironment(
        base: [String: String],
        remoteStartupCommand: String?
    ) -> [String: String] {
        guard remoteStartupCommand != nil,
              let remoteEnvironment = remoteConfiguration?.sshTerminalStartupEnvironment else {
            return base
        }
        var environment = base
        for (key, value) in remoteEnvironment {
            environment[key] = value
        }
        return environment
    }

    private func normalizedRemotePTYSessionID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private nonisolated static let remoteRelayWorkspaceIDKeys: Set<String> = [
        "workspace_id",
        "preferred_workspace_id",
        "selected_workspace_id",
        "before_workspace_id",
        "after_workspace_id",
        "from_workspace_id",
        "to_workspace_id",
    ]

    private nonisolated static let remoteRelaySurfaceIDKeys: Set<String> = [
        "panel_id",
        "surface_id",
        "preferred_panel_id",
        "preferred_surface_id",
        "target_panel_id",
        "target_surface_id",
        "created_panel_id",
        "created_surface_id",
        "before_panel_id",
        "before_surface_id",
        "after_panel_id",
        "after_surface_id",
    ]

    private nonisolated static let remoteRelayAmbiguousIDKeys: Set<String> = [
        "tab_id",
    ]

    private nonisolated static let remoteRelayWorkspaceIDArrayKeys: Set<String> = [
        "workspace_ids",
    ]

    private nonisolated static let remoteRelaySurfaceIDArrayKeys: Set<String> = [
        "panel_ids",
        "surface_ids",
    ]

    private nonisolated static let remoteRelayAmbiguousIDArrayKeys: Set<String> = [
        "tab_ids",
        "tab_id_groups",
    ]

    private func syncRemoteRelayIDAliasesToController() {
        remoteSessionController?.updateRemoteRelayIDAliases(
            workspaceAliases: remoteRelayWorkspaceIDAliases,
            surfaceAliases: remoteRelaySurfaceIDAliases
        )
    }

    private func clearRemoteRelayIDAliases() {
        guard !remoteRelayWorkspaceIDAliases.isEmpty || !remoteRelaySurfaceIDAliases.isEmpty else { return }
        remoteRelayWorkspaceIDAliases.removeAll()
        remoteRelaySurfaceIDAliases.removeAll()
        syncRemoteRelayIDAliasesToController()
    }

    private func pruneRemoteRelaySurfaceAliases(validSurfaceIds: Set<UUID>) {
        let nextAliases = remoteRelaySurfaceIDAliases.filter { validSurfaceIds.contains($0.value) }
        guard nextAliases != remoteRelaySurfaceIDAliases else { return }
        remoteRelaySurfaceIDAliases = nextAliases
        syncRemoteRelayIDAliasesToController()
    }

    private func removeRemoteRelaySurfaceAliases(targeting panelId: UUID) {
        let nextAliases = remoteRelaySurfaceIDAliases.filter { $0.value != panelId }
        guard nextAliases != remoteRelaySurfaceIDAliases else { return }
        remoteRelaySurfaceIDAliases = nextAliases
        syncRemoteRelayIDAliasesToController()
    }

    private func registerRemoteRelayIDAliases(
        snapshotWorkspaceId: UUID?,
        snapshotPanelId: UUID,
        restoredPanelId: UUID
    ) {
        var didMutate = false
        if let snapshotWorkspaceId, snapshotWorkspaceId != id {
            if remoteRelayWorkspaceIDAliases[snapshotWorkspaceId] != id {
                remoteRelayWorkspaceIDAliases[snapshotWorkspaceId] = id
                didMutate = true
            }
        }
        if snapshotPanelId != restoredPanelId {
            if remoteRelaySurfaceIDAliases[snapshotPanelId] != restoredPanelId {
                remoteRelaySurfaceIDAliases[snapshotPanelId] = restoredPanelId
                didMutate = true
            }
        }
        if didMutate {
            syncRemoteRelayIDAliasesToController()
        }
    }

    private func registerRemoteRelayIDAliases(remotePTYSessionID: String, restoredPanelId: UUID) {
        guard let parsed = Self.parsedDefaultSSHPTYSessionID(remotePTYSessionID) else { return }
        registerRemoteRelayIDAliases(
            snapshotWorkspaceId: parsed.workspaceId,
            snapshotPanelId: parsed.panelId,
            restoredPanelId: restoredPanelId
        )
    }

    func rewriteRemoteRelayCommandLine(_ commandLine: Data) -> Data {
        Self.rewriteRemoteRelayCommandLine(
            commandLine,
            workspaceAliases: remoteRelayWorkspaceIDAliases,
            surfaceAliases: remoteRelaySurfaceIDAliases
        )
    }

    nonisolated static func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        guard !workspaceAliases.isEmpty || !surfaceAliases.isEmpty,
              let line = String(data: commandLine, encoding: .utf8) else {
            return commandLine
        }
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLine.hasPrefix("{"),
              let requestData = trimmedLine.data(using: .utf8),
              var request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            return commandLine
        }

        var didRewrite = false
        if let params = request["params"] as? [String: Any] {
            request["params"] = Self.remappedRemoteRelayValue(
                params,
                key: nil,
                workspaceAliases: workspaceAliases,
                surfaceAliases: surfaceAliases,
                didRewrite: &didRewrite
            )
        }

        guard didRewrite,
              JSONSerialization.isValidJSONObject(request),
              let rewritten = try? JSONSerialization.data(withJSONObject: request, options: []) else {
            return commandLine
        }
        if commandLine.last == 0x0A {
            return rewritten + Data([0x0A])
        }
        return rewritten
    }

    private nonisolated static func remappedRemoteRelayValue(
        _ value: Any,
        key: String?,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID],
        didRewrite: inout Bool
    ) -> Any {
        if let dictionary = value as? [String: Any] {
            var result = dictionary
            for (childKey, childValue) in dictionary {
                result[childKey] = remappedRemoteRelayValue(
                    childValue,
                    key: childKey,
                    workspaceAliases: workspaceAliases,
                    surfaceAliases: surfaceAliases,
                    didRewrite: &didRewrite
                )
            }
            return result
        }

        if let array = value as? [Any] {
            let elementKey: String?
            if let key, remoteRelayWorkspaceIDArrayKeys.contains(key) {
                elementKey = "workspace_id"
            } else if let key, remoteRelaySurfaceIDArrayKeys.contains(key) {
                elementKey = "surface_id"
            } else if let key, remoteRelayAmbiguousIDArrayKeys.contains(key) {
                elementKey = "tab_id"
            } else if let key, remoteRelayWorkspaceIDKeys.contains(key)
                        || remoteRelaySurfaceIDKeys.contains(key)
                        || remoteRelayAmbiguousIDKeys.contains(key) {
                elementKey = key
            } else {
                elementKey = nil
            }
            return array.map {
                remappedRemoteRelayValue(
                    $0,
                    key: elementKey,
                    workspaceAliases: workspaceAliases,
                    surfaceAliases: surfaceAliases,
                    didRewrite: &didRewrite
                )
            }
        }

        guard let id = value as? String else {
            return value
        }

        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmedID) else {
            return value
        }

        guard let key else {
            return value
        }
        if remoteRelaySurfaceIDKeys.contains(key),
           let mapped = surfaceAliases[uuid] {
            didRewrite = true
            return mapped.uuidString
        }
        if remoteRelayWorkspaceIDKeys.contains(key),
           let mapped = workspaceAliases[uuid] {
            didRewrite = true
            return mapped.uuidString
        }
        guard remoteRelayAmbiguousIDKeys.contains(key) else {
            return value
        }

        if let mapped = workspaceAliases[uuid] {
            didRewrite = true
            return mapped.uuidString
        }
        if let mapped = surfaceAliases[uuid] {
            didRewrite = true
            return mapped.uuidString
        }

        return value
    }

    private func remotePTYSessionIDForSnapshot(panelId: UUID) -> String? {
        guard remoteConfiguration?.preserveAfterTerminalExit == true else {
            return nil
        }
        if let storedSessionID = normalizedRemotePTYSessionID(remotePTYSessionIDsByPanelId[panelId]) {
            return storedSessionID
        }
        guard activeRemoteTerminalSurfaceIds.contains(panelId) else {
            return nil
        }
        return Self.defaultSSHPTYSessionID(workspaceId: id, panelId: panelId)
    }

    nonisolated static func defaultSSHPTYSessionID(workspaceId: UUID, panelId: UUID) -> String {
        "ssh-\(workspaceId.uuidString)-\(panelId.uuidString)"
    }

    private nonisolated static func parsedDefaultSSHPTYSessionID(_ value: String) -> (workspaceId: UUID, panelId: UUID)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ssh-") else { return nil }
        let suffix = String(trimmed.dropFirst(4))
        guard suffix.count == 73 else { return nil }
        let separatorIndex = suffix.index(suffix.startIndex, offsetBy: 36)
        guard suffix[separatorIndex] == "-" else { return nil }
        let panelStart = suffix.index(after: separatorIndex)
        let workspacePart = String(suffix[..<separatorIndex])
        let panelPart = String(suffix[panelStart...])
        guard let workspaceId = UUID(uuidString: workspacePart),
              let panelId = UUID(uuidString: panelPart) else {
            return nil
        }
        return (workspaceId, panelId)
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
        remotePTYSessionIDsByPanelId.removeValue(forKey: panelId)
        endedPersistentRemotePTYAttachSurfaceIds.remove(panelId)
        removeRemoteRelaySurfaceAliases(targeting: panelId)
    }

    func remotePTYSessionIDMatches(panelId: UUID, sessionID: String?) -> Bool {
        guard activeRemoteTerminalSurfaceIds.contains(panelId),
              let normalizedSessionID = normalizedRemotePTYSessionID(sessionID) else {
            return false
        }
        let expectedSessionID = normalizedRemotePTYSessionID(remotePTYSessionIDsByPanelId[panelId])
            ?? Self.defaultSSHPTYSessionID(workspaceId: id, panelId: panelId)
        return normalizedSessionID == expectedSessionID
    }

    @discardableResult
    func markRemotePTYAttachEnded(surfaceId: UUID, sessionID: String) -> (clearedRemotePTYSession: Bool, untrackedRemoteTerminal: Bool) {
        let normalizedSessionID = normalizedRemotePTYSessionID(sessionID)
        let expectedSessionID = normalizedRemotePTYSessionID(remotePTYSessionIDsByPanelId[surfaceId])
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
        remotePTYSessionIDsByPanelId.removeValue(forKey: surfaceId)
        removeRemoteRelaySurfaceAliases(targeting: surfaceId)
        untrackRemoteTerminalSurface(surfaceId)
        return (true, wasTracked)
    }

    func markPersistentRemotePTYAttachFailed(surfaceId: UUID) {
        guard remoteConfiguration?.preserveAfterTerminalExit == true else { return }

        remotePTYSessionIDsByPanelId.removeValue(forKey: surfaceId)
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
    func rememberPendingRemoteSurfacePWD(_ path: String, requestedSurfaceId: UUID?) {
        guard path.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil else { return }
        pendingRemoteSurfacePWD = path
        pendingRemoteSurfacePWDSurfaceId = requestedSurfaceId
    }

    @MainActor
    @discardableResult
    private func applyPendingRemoteSurfacePWDIfNeeded(to panelId: UUID) -> Bool {
        guard let path = pendingRemoteSurfacePWD,
              path.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil else {
            return false
        }
        if let requestedSurfaceId = pendingRemoteSurfacePWDSurfaceId,
           requestedSurfaceId != panelId {
            return false
        }
        pendingRemoteSurfacePWD = nil
        pendingRemoteSurfacePWDSurfaceId = nil
        return updatePanelDirectory(panelId: panelId, directory: path)
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
        guard let arguments = sshControlMasterCleanupArguments(configuration: configuration) else { return }
        if let override = runSSHControlMasterCommandOverrideForTesting {
            override(arguments)
            return
        }

        sshControlMasterCleanupQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            process.environment = configuration.sshProcessEnvironment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let exitSemaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in
                exitSemaphore.signal()
            }

            do {
                try process.run()
                if exitSemaphore.wait(timeout: .now() + 5) == .timedOut {
                    if process.isRunning {
                        process.terminate()
                    }
                    _ = exitSemaphore.wait(timeout: .now() + 1)
                }
            } catch {
                return
            }
        }
    }

    private static func sshControlMasterCleanupArguments(configuration: WorkspaceRemoteConfiguration) -> [String]? {
        let sshOptions = normalizedSSHControlCleanupOptions(configuration.sshOptions)
        var arguments: [String] = [
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
        ]
        if let port = configuration.port {
            arguments += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines),
           !identityFile.isEmpty {
            arguments += ["-i", identityFile]
        }
        for option in sshOptions {
            arguments += ["-o", option]
        }
        arguments += ["-O", "exit", configuration.destination]
        return arguments
    }

    private static func normalizedSSHControlCleanupOptions(_ options: [String]) -> [String] {
        let disallowedKeys: Set<String> = ["controlmaster", "controlpersist"]
        return options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let key = sshOptionKeyForControlCleanup(trimmed) else { return nil }
            return disallowedKeys.contains(key) ? nil : trimmed
        }
    }

    private static func sshOptionKeyForControlCleanup(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    func applyRemoteConnectionStateUpdate(
        _ state: WorkspaceRemoteConnectionState,
        detail: String?,
        target: String
    ) {
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxyOnlyError = trimmedDetail.map(Self.isProxyOnlyRemoteError) ?? false
        let preserveConnectedStateForRetry =
            (state == .connecting || state == .reconnecting) &&
                preservesProxyFailureWhileSSHTerminalIsAlive &&
                hasProxyOnlyRemoteSidebarError
        let effectiveState: WorkspaceRemoteConnectionState
        if state == .error && proxyOnlyError && preservesProxyFailureWhileSSHTerminalIsAlive {
            effectiveState = .connected
        } else if preserveConnectedStateForRetry {
            effectiveState = .connected
        } else {
            effectiveState = state
        }

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
                AppDelegate.shared?.notificationStore?.addNotification(
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
                AppDelegate.shared?.notificationStore?.addNotification(
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

    private func resolvedTerminalInheritanceFontPoints(
        for terminalPanel: TerminalPanel,
        sourceSurface: ghostty_surface_t,
        inheritedConfig: CmuxSurfaceConfigTemplate
    ) -> Float? {
        let runtimeBasePoints = cmuxCurrentSurfaceFontSizePoints(sourceSurface).map { CmuxSurfaceConfigTemplate.baseFontSize(fromRuntimePoints: $0, percent: GlobalFontMagnification.storedPercent) }
        if let rooted = terminalInheritanceFontPointsByPanelId[terminalPanel.id], rooted > 0 {
            if let runtimeBasePoints, abs(runtimeBasePoints - rooted) > 0.05 {
                // Runtime zoom changed after lineage was seeded (manual zoom on descendant);
                // treat runtime as the new root for future descendants.
                return runtimeBasePoints
            }
            return rooted
        }
        if inheritedConfig.fontSize > 0 {
            return inheritedConfig.fontSize
        }
        return runtimeBasePoints
    }

    private func rememberTerminalConfigInheritanceSource(_ terminalPanel: TerminalPanel) {
        lastTerminalConfigInheritancePanelId = terminalPanel.id
        if let sourceSurface = terminalPanel.surface.surface,
           let runtimePoints = cmuxCurrentSurfaceFontSizePoints(sourceSurface) {
            let runtimeBasePoints = CmuxSurfaceConfigTemplate.baseFontSize(fromRuntimePoints: runtimePoints, percent: GlobalFontMagnification.storedPercent)
            let existing = terminalInheritanceFontPointsByPanelId[terminalPanel.id]
            if existing == nil || abs((existing ?? runtimeBasePoints) - runtimeBasePoints) > 0.05 {
                terminalInheritanceFontPointsByPanelId[terminalPanel.id] = runtimeBasePoints
            }
            lastTerminalConfigInheritanceFontPoints = terminalInheritanceFontPointsByPanelId[terminalPanel.id] ?? runtimeBasePoints
        }
    }

    func lastRememberedTerminalPanelForConfigInheritance() -> TerminalPanel? {
        guard let panelId = lastTerminalConfigInheritancePanelId else { return nil }
        return terminalPanel(for: panelId)
    }

    func lastRememberedTerminalFontPointsForConfigInheritance() -> Float? {
        lastTerminalConfigInheritanceFontPoints
    }

    nonisolated private static func normalizedTerminalWorkingDirectory(_ workingDirectory: String?) -> String? {
        let trimmed = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resolvedTerminalStartupWorkingDirectory(
        requestedWorkingDirectory: String?,
        sourcePanelId: UUID?
    ) -> String? {
        [
            requestedWorkingDirectory,
            sourcePanelId.flatMap { panelDirectories[$0] },
            sourcePanelId.flatMap { terminalPanel(for: $0)?.requestedWorkingDirectory },
            currentDirectory,
        ].lazy.compactMap(Self.normalizedTerminalWorkingDirectory).first
    }

    /// The directory a new tab (`new-window`) should inherit in a remote-tmux
    /// mirror: strictly the source tab's last-reported `#{pane_current_path}`
    /// (`panelDirectories[sourcePanelId]`), or nil when the remote has not
    /// reported one yet.
    ///
    /// It must not use ``resolvedTerminalStartupWorkingDirectory(requestedWorkingDirectory:sourcePanelId:)``:
    /// that resolver falls back to `currentDirectory`, which on a mirror
    /// workspace is seeded from the local workspace and so can be a local
    /// filesystem path. A local path is meaningless on the remote host — as
    /// `new-window -c` it would open the tab somewhere other than the active
    /// tab's directory. Only `panelDirectories[sourcePanelId]`, fed by the tab's
    /// remote cwd reports, is a correct remote-side source.
    func remoteTmuxNewWindowWorkingDirectory(forSourcePanelId sourcePanelId: UUID?) -> String? {
        Self.normalizedTerminalWorkingDirectory(sourcePanelId.flatMap { panelDirectories[$0] })
    }

    /// Placement for a remote-tmux mirror `new-window` request.
    ///
    /// Targeted entrypoints such as "new terminal to right" pass an explicit
    /// anchor panel and rely on local tab reordering after creation. A mirror
    /// cannot locally reorder a tmux-created window, so the remote command must
    /// target that anchor directly. Plain new-tab requests have no explicit
    /// anchor and follow the workspace's tab-strip `newTabPosition`.
    func remoteTmuxNewTabPlacement(
        inPane paneId: PaneID,
        anchorPanelId: UUID?
    ) -> RemoteTmuxMirrorNewTabPlacement {
        if let anchorPanelId {
            return .afterPanel(anchorPanelId)
        }
        switch bonsplitController.configuration.newTabPosition {
        case .end:
            return .end
        case .current:
            if let selectedPanelId = selectedTerminalPanelId(inPane: paneId) {
                return .afterPanel(selectedPanelId)
            }
            return .end
        }
    }

    private func selectedTerminalPanelId(inPane paneId: PaneID) -> UUID? {
        bonsplitController.selectedTab(inPane: paneId).map(\.id).flatMap(panelIdFromSurfaceId)
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
        // Walk candidates in priority order and use the first panel that still exposes
        // a runtime surface pointer.
        for terminalPanel in terminalPanelConfigInheritanceCandidates(
            preferredPanelId: preferredPanelId,
            inPane: preferredPaneId
        ) {
            // Pin the panel and its TerminalSurface wrapper for the duration of
            // this iteration. The raw ghostty_surface_t extracted below is owned
            // by `surface` (the TerminalSurface) — ARC must not release it while
            // ghostty_surface_inherited_config or cmuxCurrentSurfaceFontSizePoints
            // is still reading through the pointer.
            let surface = terminalPanel.surface
            guard let sourceSurface = surface.surface else { continue }
            var config = cmuxInheritedSurfaceConfig(
                sourceSurface: sourceSurface,
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT
            )
            if let rootedFontPoints = resolvedTerminalInheritanceFontPoints(
                for: terminalPanel,
                sourceSurface: sourceSurface,
                inheritedConfig: config
            ), rootedFontPoints > 0 {
                config.fontSize = rootedFontPoints
                terminalInheritanceFontPointsByPanelId[terminalPanel.id] = rootedFontPoints
            }
            // Prevent ARC from releasing panel/surface before the C calls above complete.
            withExtendedLifetime((terminalPanel, surface)) {}
            rememberTerminalConfigInheritanceSource(terminalPanel)
            if config.fontSize > 0 {
                lastTerminalConfigInheritanceFontPoints = config.fontSize
            }
            return config
        }

        if let fallbackFontPoints = lastTerminalConfigInheritanceFontPoints {
            var config = CmuxSurfaceConfigTemplate()
            config.fontSize = fallbackFontPoints
#if DEBUG
            cmuxDebugLog(
                "zoom.inherit fallback=lastKnownFont context=split font=\(String(format: "%.2f", fallbackFontPoints))"
            )
#endif
            return config
        }

        return nil
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
            let routed = AppDelegate.shared?.remoteTmuxController.handleMirrorTabSplitRequested(
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
        // Find the pane containing the source panel
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }
        var inheritedConfig = inheritedTerminalConfig(preferredPanelId: panelId, inPane: paneId)
        let requestedInitialCommand = initialCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitInitialCommand = (requestedInitialCommand?.isEmpty == false) ? requestedInitialCommand : nil
        let remoteTerminalStartupCommand = remoteTerminalStartupCommand()
        let startupCommand = explicitInitialCommand ?? remoteTerminalStartupCommand
        let remoteStartupCommandForEnvironment = explicitInitialCommand == nil ? remoteTerminalStartupCommand : nil
        let effectiveStartupEnvironment = terminalStartupEnvironment(
            base: startupEnvironmentMergingWorkspaceEnvironment(startupEnvironment),
            remoteStartupCommand: remoteStartupCommandForEnvironment
        )
        // Hold the pane open after the remote session ends so the user can read the
        // "ssh exited …" message the startup script prints. Otherwise Ghostty silently
        // respawns a local login shell when the command exits (the PTY falls through
        // to $SHELL), and a dead VM looks identical to a healthy workspace with a
        // local prompt — which is what we saw during dogfood.
        if startupCommand != nil {
            var template = inheritedConfig ?? CmuxSurfaceConfigTemplate()
            template.waitAfterCommand = true
            inheritedConfig = template
        }
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
        let tracksRemoteTerminalSurface = remoteTerminalStartupCommand != nil || normalizedRemotePTYSessionID != nil
        if let normalizedRemotePTYSessionID {
            remotePTYSessionIDsByPanelId[newPanel.id] = normalizedRemotePTYSessionID
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
        bindSurface(newTab.id, toPanelId: newPanel.id)
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
            remotePTYSessionIDsByPanelId.removeValue(forKey: newPanel.id)
            removeRemoteRelaySurfaceAliases(targeting: newPanel.id)
            removeSurfaceMapping(forSurfaceId: newTab.id)
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
        // In a remote tmux mirror, a new tab means "create a tmux window"; never
        // create a local orphan the mirror can't reconcile. Dead mirrors are
        // torn down via handleSessionEndedRemotely.
        if isRemoteTmuxMirror {
            let anchorPanelId = workingDirectoryFallbackSourcePanelId
            let placement = remoteTmuxNewTabPlacement(inPane: paneId, anchorPanelId: anchorPanelId)
            // Inherit the active tab's directory like a local new tab, sourcing it
            // only from that tab's confirmed remote cwd (see
            // remoteTmuxNewWindowWorkingDirectory). The socket/CLI layer rejects an
            // explicit working_directory for mirror workspaces
            // (mirrorRoutedUnsupportedOptions), so inheritance is the only source.
            let inheritSourcePanelId = inheritWorkingDirectoryFallback
                ? anchorPanelId ?? selectedTerminalPanelId(inPane: paneId)
                : nil
            let resolvedWorkingDirectory: String?
            if let inheritSourcePanelId {
                resolvedWorkingDirectory = remoteTmuxNewWindowWorkingDirectory(forSourcePanelId: inheritSourcePanelId)
            } else {
                resolvedWorkingDirectory = nil
            }
            let routed = AppDelegate.shared?.remoteTmuxController
                .handleMirrorNewTabRequested(
                    workspaceId: id,
                    placement: placement,
                    workingDirectory: resolvedWorkingDirectory,
                    workingDirectorySourcePanelId: inheritSourcePanelId
                ) ?? false
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
        let requestedInitialCommand = initialCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitInitialCommand = (requestedInitialCommand?.isEmpty == false) ? requestedInitialCommand : nil
        let remoteTerminalStartupCommand = suppressWorkspaceRemoteStartupCommand ? nil : remoteTerminalStartupCommand()
        let startupCommand = explicitInitialCommand ?? remoteTerminalStartupCommand
        let remoteStartupCommandForEnvironment = explicitInitialCommand == nil ? remoteTerminalStartupCommand : nil
        let effectiveStartupEnvironment = terminalStartupEnvironment(
            base: startupEnvironmentMergingWorkspaceEnvironment(startupEnvironment),
            remoteStartupCommand: remoteStartupCommandForEnvironment
        )
        // See the comment at the other call site: hold the PTY open after the remote
        // command exits so the user sees the error rather than a silently-respawned
        // local login shell.
        if startupCommand != nil {
            var template = inheritedConfig ?? CmuxSurfaceConfigTemplate()
            template.waitAfterCommand = true
            inheritedConfig = template
        }
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
        let tracksRemoteTerminalSurface = remoteTerminalStartupCommand != nil || normalizedRemotePTYSessionID != nil
        if let normalizedRemotePTYSessionID {
            remotePTYSessionIDsByPanelId[newPanel.id] = normalizedRemotePTYSessionID
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
            remotePTYSessionIDsByPanelId.removeValue(forKey: newPanel.id)
            removeRemoteRelaySurfaceAliases(targeting: newPanel.id)
            if tracksRemoteTerminalSurface {
                untrackRemoteTerminalSurface(newPanel.id)
            }
            terminalInheritanceFontPointsByPanelId.removeValue(forKey: newPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: newPanel.id)
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
        bindSurface(newTabId, toPanelId: newPanel.id)
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
    func requestRemoteTmuxPaneClose(windowMirror: RemoteTmuxWindowMirror, tmuxPaneId: Int) {
        // Close warnings disabled → even an active command wouldn't confirm;
        // kill with no added round trip.
        guard CloseTabWarningStore(defaults: closeTabWarningDefaults).shouldConfirmClose(
            requiresConfirmation: true, source: .tabCloseButton
        ) else {
            windowMirror.requestKillPane(tmuxPaneId)
            return
        }
        guard !pendingRemoteTmuxPaneCloseIds.contains(tmuxPaneId) else { return }
        pendingRemoteTmuxPaneCloseIds.insert(tmuxPaneId)
        windowMirror.queryPaneActivity(tmuxPaneId) { [weak self, weak windowMirror] states in
            // Hop off the control-stream dispatch before a (modal) dialog can
            // block it; the defer keeps the in-flight guard balanced on every path.
            Task { @MainActor [weak self, weak windowMirror] in
                guard let self else { return }
                defer { self.pendingRemoteTmuxPaneCloseIds.remove(tmuxPaneId) }
                guard let windowMirror else { return }
                let state = states?[tmuxPaneId] ?? windowMirror.paneForegroundState(tmuxPaneId)
                if CloseTabWarningStore(defaults: closeTabWarningDefaults).shouldConfirmClose(
                    requiresConfirmation: state?.hasActiveCommand ?? false,
                    source: .tabCloseButton
                ) {
                    // No manager → no way to ask → refuse the destructive kill rather
                    // than falling through to an unconfirmed one (only reachable in
                    // teardown states where the pane header shouldn't be clickable).
                    guard let manager = self.owningTabManager
                        ?? AppDelegate.shared?.tabManagerFor(tabId: self.id)
                        ?? AppDelegate.shared?.tabManager else { return }
                    let message: String
                    if let command = state?.command, state?.hasActiveCommand == true, !command.isEmpty {
                        message = String(localized: "dialog.closeTab.messageNamed", defaultValue: "This will close \"\(command)\".")
                    } else {
                        message = String(localized: "dialog.closeTab.message", defaultValue: "This will close the current tab.")
                    }
                    guard manager.confirmClose(
                        title: String(localized: "dialog.closeTab.title", defaultValue: "Close tab?"),
                        message: message,
                        acceptCmdD: false
                    ) else { return }
                }
                windowMirror.requestKillPane(tmuxPaneId)
            }
        }
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
        bindSurface(tabId, toPanelId: panelId)
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

    private func remoteTerminalStartupCommand() -> String? {
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

        // Find the pane containing the source panel
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }

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
            isAudioPlaying: browserPanel.isPlayingAudio,
            isPinned: false
        )
        bindSurface(newTab.id, toPanelId: browserPanel.id)
        let previousFocusedPanelId = focusedPanelId

        // Create the split with the browser tab already present.
        // Mark this split as programmatic so didSplitPane doesn't auto-create a terminal.
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) else {
            removeSurfaceMapping(forSurfaceId: newTab.id)
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
            isAudioPlaying: browserPanel.isPlayingAudio,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: browserPanel.id)
            panelTitles.removeValue(forKey: browserPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: browserPanel.id)
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
    @discardableResult
    func newSidebarExtensionBrowserSurface(
        inPane paneId: PaneID,
        title: String,
        focus: Bool = true
    ) -> CMUXSidebarExtensionBrowserPanel? {
        let shouldFocusNewTab = focus || bonsplitController.focusedPaneId == paneId
        let extensionBrowserPanel = CMUXSidebarExtensionBrowserPanel(title: title)
        panels[extensionBrowserPanel.id] = extensionBrowserPanel
        panelTitles[extensionBrowserPanel.id] = extensionBrowserPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: extensionBrowserPanel.displayTitle,
            icon: extensionBrowserPanel.displayIcon,
            kind: SurfaceKind.extensionBrowser.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: extensionBrowserPanel.id)
            panelTitles.removeValue(forKey: extensionBrowserPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: extensionBrowserPanel.id)
        publishCmuxSurfaceCreated(
            extensionBrowserPanel.id,
            paneId: paneId,
            kind: SurfaceKind.extensionBrowser.rawValue,
            origin: "extension_browser_tab",
            focused: shouldFocusNewTab
        )

        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            extensionBrowserPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        }

        return extensionBrowserPanel
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
        let canonical = (filePath as NSString).resolvingSymlinksInPath
        for (existingId, panel) in panels {
            guard let md = panel as? MarkdownPanel else { continue }
            if (md.filePath as NSString).resolvingSymlinksInPath == canonical {
                focusPanel(existingId)
                return md
            }
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

    func newMarkdownSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        filePath: String,
        focus: Bool = true,
        fontSize: Double? = nil
    ) -> MarkdownPanel? {
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }

        let markdownPanel = MarkdownPanel(workspaceId: id, filePath: filePath, fontSize: fontSize)
        panels[markdownPanel.id] = markdownPanel
        panelTitles[markdownPanel.id] = markdownPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: markdownPanel.displayTitle,
            icon: markdownPanel.displayIcon,
            kind: SurfaceKind.markdown.rawValue,
            isDirty: markdownPanel.isDirty,
            isLoading: false,
            isPinned: false
        )
        bindSurface(newTab.id, toPanelId: markdownPanel.id)
        let previousFocusedPanelId = focusedPanelId

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) else {
            removeSurfaceMapping(forSurfaceId: newTab.id)
            panels.removeValue(forKey: markdownPanel.id)
            panelTitles.removeValue(forKey: markdownPanel.id)
            return nil
        }
        publishCmuxSplitCreated(newPaneId, sourcePaneId: paneId, orientation: orientation, surfaceId: markdownPanel.id, kind: "markdown", origin: "markdown_split", focused: focus)

        let previousHostedView = focusedTerminalPanel?.hostedView
        if focus {
            suppressReparentFocusUntilLayoutFollowUp(
                previousHostedView,
                reason: "workspace.markdownSplitReparent"
            )
            focusPanel(markdownPanel.id)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: markdownPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installMarkdownPanelSubscription(markdownPanel)
        return markdownPanel
    }

    @discardableResult
    func newMarkdownSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> MarkdownPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let markdownPanel = MarkdownPanel(workspaceId: id, filePath: filePath)
        panels[markdownPanel.id] = markdownPanel
        panelTitles[markdownPanel.id] = markdownPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: markdownPanel.displayTitle,
            icon: markdownPanel.displayIcon,
            kind: SurfaceKind.markdown.rawValue,
            isDirty: markdownPanel.isDirty,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: markdownPanel.id)
            panelTitles.removeValue(forKey: markdownPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: markdownPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(markdownPanel.id, paneId: paneId, kind: "markdown", origin: "markdown_tab", focused: shouldFocusNewTab)
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: markdownPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installMarkdownPanelSubscription(markdownPanel)
        return markdownPanel
    }

    @discardableResult
    func newProjectSurface(
        inPane paneId: PaneID,
        projectPath: String,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> ProjectPanel? {
        guard !projectPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath).standardizedFileURL
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let projectPanel = ProjectPanel(projectURL: url)
        panels[projectPanel.id] = projectPanel
        panelTitles[projectPanel.id] = projectPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: projectPanel.displayTitle,
            icon: projectPanel.displayIcon,
            kind: SurfaceKind.project.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: projectPanel.id)
            panelTitles.removeValue(forKey: projectPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: projectPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(projectPanel.id, paneId: paneId, kind: SurfaceKind.project.rawValue, origin: "project_tab", focused: shouldFocusNewTab)
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: projectPanel.id,
                previousHostedView: previousHostedView
            )
        }

        projectPanel.reload()
        return projectPanel
    }

    @discardableResult
    func openOrFocusMarkdownSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool = true
    ) -> MarkdownPanel? {
        let canonical = (filePath as NSString).resolvingSymlinksInPath
        for (existingId, panel) in panels {
            guard let markdownPanel = panel as? MarkdownPanel else { continue }
            if (markdownPanel.filePath as NSString).resolvingSymlinksInPath == canonical {
                if focus {
                    focusPanel(existingId)
                }
                return markdownPanel
            }
        }

        return newMarkdownSurface(inPane: paneId, filePath: filePath, focus: focus)
    }

    @discardableResult
    func splitPaneWithMarkdown(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        filePath: String
    ) -> MarkdownPanel? {
        let markdownPanel = MarkdownPanel(workspaceId: id, filePath: filePath)
        panels[markdownPanel.id] = markdownPanel
        panelTitles[markdownPanel.id] = markdownPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: markdownPanel.displayTitle,
            icon: markdownPanel.displayIcon,
            kind: SurfaceKind.markdown.rawValue,
            isDirty: markdownPanel.isDirty,
            isLoading: false,
            isPinned: false
        )
        bindSurface(newTab.id, toPanelId: markdownPanel.id)

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard bonsplitController.splitPane(
            paneId,
            orientation: orientation,
            withTab: newTab,
            insertFirst: insertFirst
        ) != nil else {
            panels.removeValue(forKey: markdownPanel.id)
            panelTitles.removeValue(forKey: markdownPanel.id)
            removeSurfaceMapping(forSurfaceId: newTab.id)
            return nil
        }

        bonsplitController.selectTab(newTab.id)
        focusPanel(markdownPanel.id)
        installMarkdownPanelSubscription(markdownPanel)
        return markdownPanel
    }

    @discardableResult
    func openOrFocusFilePreviewSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool = true
    ) -> FilePreviewPanel? {
        let canonical = (filePath as NSString).resolvingSymlinksInPath
        for (existingId, panel) in panels {
            guard let preview = panel as? FilePreviewPanel else { continue }
            if (preview.filePath as NSString).resolvingSymlinksInPath == canonical {
                if focus {
                    focusPanel(existingId)
                }
                return preview
            }
        }

        return newFilePreviewSurface(inPane: paneId, filePath: filePath, focus: focus)
    }

    @discardableResult
    func openOrFocusFilePreviewSplit(
        from panelId: UUID,
        filePath: String
    ) -> FilePreviewPanel? {
        let canonical = (filePath as NSString).resolvingSymlinksInPath
        for (existingId, panel) in panels {
            guard let preview = panel as? FilePreviewPanel else { continue }
            if (preview.filePath as NSString).resolvingSymlinksInPath == canonical {
                focusPanel(existingId)
                return preview
            }
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

    @discardableResult
    func newFilePreviewSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> FilePreviewPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let filePreviewPanel = FilePreviewPanel(workspaceId: id, filePath: filePath)
        panels[filePreviewPanel.id] = filePreviewPanel
        panelTitles[filePreviewPanel.id] = filePreviewPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: filePreviewPanel.displayTitle,
            icon: RenderableSystemSymbol.resolvedSurfaceTabIcon(filePreviewPanel.displayIcon),
            kind: SurfaceKind.filePreview.rawValue,
            isDirty: filePreviewPanel.isDirty,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: filePreviewPanel.id)
            panelTitles.removeValue(forKey: filePreviewPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: filePreviewPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(filePreviewPanel.id, paneId: paneId, kind: "file_preview", origin: "file_preview_tab", focused: shouldFocusNewTab)
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            filePreviewPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: filePreviewPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installFilePreviewPanelSubscription(filePreviewPanel)
        return filePreviewPanel
    }

    @discardableResult
    func openOrFocusRightSidebarToolSurface(
        inPane paneId: PaneID,
        mode: RightSidebarMode,
        focus: Bool = true
    ) -> RightSidebarToolPanel? {
        guard mode.canOpenAsPane else { return nil }
        for (existingId, panel) in panels {
            guard let toolPanel = panel as? RightSidebarToolPanel,
                  toolPanel.mode == mode else {
                continue
            }
            if focus {
                focusPanel(existingId)
            }
            return toolPanel
        }
        return newRightSidebarToolSurface(inPane: paneId, mode: mode, focus: focus)
    }

    @discardableResult
    func newRightSidebarToolSurface(
        inPane paneId: PaneID,
        mode: RightSidebarMode,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> RightSidebarToolPanel? {
        guard mode.canOpenAsPane else { return nil }
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let toolPanel = RightSidebarToolPanel(workspace: self, mode: mode)
        panels[toolPanel.id] = toolPanel
        panelTitles[toolPanel.id] = toolPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: toolPanel.displayTitle,
            icon: toolPanel.displayIcon,
            kind: SurfaceKind.rightSidebarTool.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: toolPanel.id)
            panelTitles.removeValue(forKey: toolPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: toolPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(toolPanel.id, paneId: paneId, kind: "right_sidebar_tool", origin: "right_sidebar_tool_tab", focused: shouldFocusNewTab)

        if shouldFocusNewTab {
            focusPanel(toolPanel.id)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: toolPanel.id,
                previousHostedView: previousHostedView
            )
        }

        return toolPanel
    }

    @discardableResult
    func newAgentSessionSurface(
        inPane paneId: PaneID,
        providerID: AgentSessionProviderID = .codex,
        rendererKind: AgentSessionRendererKind,
        workingDirectory: String? = nil,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> AgentSessionPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView
        let directory = workingDirectory ?? currentDirectory

        let agentPanel = AgentSessionPanel(
            workspaceId: id,
            rendererKind: rendererKind,
            initialProviderID: providerID,
            workingDirectory: directory
        )
        panels[agentPanel.id] = agentPanel
        panelTitles[agentPanel.id] = agentPanel.displayTitle
        if !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panelDirectories[agentPanel.id] = directory
        }

        guard let newTabId = bonsplitController.createTab(
            title: agentPanel.displayTitle,
            icon: agentPanel.displayIcon,
            kind: SurfaceKind.agentSession.rawValue,
            isDirty: agentPanel.isDirty,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: agentPanel.id)
            panelTitles.removeValue(forKey: agentPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: agentPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(
            agentPanel.id,
            paneId: paneId,
            kind: "agent_session",
            origin: "agent_session_tab",
            focused: shouldFocusNewTab
        )

        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            agentPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: agentPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installAgentSessionPanelSubscription(agentPanel)

        return agentPanel
    }

    @discardableResult
    func splitPaneWithFilePreview(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        filePath: String
    ) -> FilePreviewPanel? {
        let filePreviewPanel = FilePreviewPanel(workspaceId: id, filePath: filePath)
        panels[filePreviewPanel.id] = filePreviewPanel
        panelTitles[filePreviewPanel.id] = filePreviewPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: filePreviewPanel.displayTitle,
            icon: RenderableSystemSymbol.resolvedSurfaceTabIcon(filePreviewPanel.displayIcon),
            kind: SurfaceKind.filePreview.rawValue,
            isDirty: filePreviewPanel.isDirty,
            isLoading: false,
            isPinned: false
        )
        bindSurface(newTab.id, toPanelId: filePreviewPanel.id)

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) else {
            panels.removeValue(forKey: filePreviewPanel.id)
            panelTitles.removeValue(forKey: filePreviewPanel.id)
            removeSurfaceMapping(forSurfaceId: newTab.id)
            return nil
        }
        publishCmuxSplitCreated(newPaneId, sourcePaneId: paneId, orientation: orientation, surfaceId: filePreviewPanel.id, kind: "file_preview", origin: "file_preview_split", focused: true)

        bonsplitController.selectTab(newTab.id)
        filePreviewPanel.focus()
        installFilePreviewPanelSubscription(filePreviewPanel)
        return filePreviewPanel
    }

    /// Tear down all panels before removing the workspace.
    func teardownAllPanels() {
        portalRenderingEnabled = false
        clearLayoutFollowUp()
        hideAllTerminalPortalViews()
        hideAllBrowserPortalViews()
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
        pruneSurfaceMetadata(validSurfaceIds: [])
        syncRemotePortScanTTYs()
        recomputeListeningPorts()
        clearRemoteConfigurationIfWorkspaceBecameLocal()
        restoredTerminalScrollbackByPanelId.removeAll(keepingCapacity: false)
#if DEBUG
        debugSessionSnapshotScrollbackFallbackPanelIds.removeAll(keepingCapacity: false)
        debugSessionSnapshotSyntheticScrollbackByPanelId.removeAll(keepingCapacity: false)
#endif
        pendingTerminalInputObserversByPanelId.removeAll(keepingCapacity: false)
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
        if force { forceCloseTabIds.insert(tabId) }
        let closed = bonsplitController.closeTab(tabId); if force && !closed { forceCloseTabIds.remove(tabId) }
        return closed
    }

    func paneId(forPanelId panelId: UUID) -> PaneID? {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return nil }
        return bonsplitController.allPaneIds.first { paneId in
            bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId })
        }
    }

    private func applyInitialSplitDividerPosition(_ position: CGFloat?, sourcePaneId: PaneID, newPaneId: PaneID) {
        guard let position,
              let splitId = splitIdJoiningPaneIds(
                sourcePaneId.id.uuidString,
                newPaneId.id.uuidString,
                in: bonsplitController.treeSnapshot()
              ) else { return }
        _ = bonsplitController.setDividerPosition(position, forSplit: splitId, fromExternal: true)
    }

    private func splitIdJoiningPaneIds(_ firstPaneId: String, _ secondPaneId: String, in node: ExternalTreeNode) -> UUID? {
        switch node {
        case .pane:
            return nil
        case .split(let splitNode):
            let firstContainsFirst = splitTreeContainsPane(firstPaneId, in: splitNode.first)
            let firstContainsSecond = splitTreeContainsPane(secondPaneId, in: splitNode.first)
            let secondContainsFirst = splitTreeContainsPane(firstPaneId, in: splitNode.second)
            let secondContainsSecond = splitTreeContainsPane(secondPaneId, in: splitNode.second)
            if (firstContainsFirst && secondContainsSecond) || (firstContainsSecond && secondContainsFirst) {
                return UUID(uuidString: splitNode.id)
            }
            return splitIdJoiningPaneIds(firstPaneId, secondPaneId, in: splitNode.first)
                ?? splitIdJoiningPaneIds(firstPaneId, secondPaneId, in: splitNode.second)
        }
    }

    private func splitTreeContainsPane(_ paneId: String, in node: ExternalTreeNode) -> Bool {
        switch node {
        case .pane(let pane):
            return pane.id == paneId
        case .split(let split):
            return splitTreeContainsPane(paneId, in: split.first)
                || splitTreeContainsPane(paneId, in: split.second)
        }
    }

    func indexInPane(forPanelId panelId: UUID) -> Int? {
        guard let tabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId) else { return nil }
        return bonsplitController.tabs(inPane: paneId).firstIndex(where: { $0.id == tabId })
    }

    /// Returns the nearest right-side sibling pane for browser/file-preview placement.
    /// The search is local to the source pane's ancestry in the split tree:
    /// use the closest horizontal ancestor where the source is in the first (left) branch.
    func preferredRightSideTargetPane(fromPanelId panelId: UUID) -> PaneID? {
        guard let sourcePane = paneId(forPanelId: panelId) else { return nil }
        let sourcePaneId = sourcePane.id.uuidString
        let tree = bonsplitController.treeSnapshot()
        guard let path = browserPathToPane(targetPaneId: sourcePaneId, node: tree) else { return nil }

        let layout = bonsplitController.layoutSnapshot()
        let paneFrameById = Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.paneId, $0.frame) })
        let sourceFrame = paneFrameById[sourcePaneId]
        let sourceCenterY = sourceFrame.map { $0.y + ($0.height * 0.5) } ?? 0
        let sourceRightX = sourceFrame.map { $0.x + $0.width } ?? 0

        for crumb in path {
            guard crumb.split.orientation == "horizontal", crumb.branch == .first else { continue }
            var candidateNodes: [ExternalPaneNode] = []
            browserCollectPaneNodes(node: crumb.split.second, into: &candidateNodes)
            if candidateNodes.isEmpty { continue }

            let sorted = candidateNodes.sorted { lhs, rhs in
                let lhsDy = abs((lhs.frame.y + (lhs.frame.height * 0.5)) - sourceCenterY)
                let rhsDy = abs((rhs.frame.y + (rhs.frame.height * 0.5)) - sourceCenterY)
                if lhsDy != rhsDy { return lhsDy < rhsDy }

                let lhsDx = abs(lhs.frame.x - sourceRightX)
                let rhsDx = abs(rhs.frame.x - sourceRightX)
                if lhsDx != rhsDx { return lhsDx < rhsDx }

                if lhs.frame.x != rhs.frame.x { return lhs.frame.x < rhs.frame.x }
                return lhs.id < rhs.id
            }

            for candidate in sorted {
                guard let candidateUUID = UUID(uuidString: candidate.id),
                      candidateUUID != sourcePane.id,
                      let pane = bonsplitController.allPaneIds.first(where: { $0.id == candidateUUID }) else {
                    continue
                }
                return pane
            }
        }

        return nil
    }

    /// Returns the top-right pane in the current split tree.
    /// When a workspace is already split, sidebar PR opens should reuse an existing pane
    /// instead of creating additional right splits.
    func topRightBrowserReusePane() -> PaneID? {
        let paneIds = bonsplitController.allPaneIds
        guard paneIds.count > 1 else { return nil }

        let paneById = Dictionary(uniqueKeysWithValues: paneIds.map { ($0.id.uuidString, $0) })
        var paneBounds: [String: CGRect] = [:]
        browserCollectNormalizedPaneBounds(
            node: bonsplitController.treeSnapshot(),
            availableRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            into: &paneBounds
        )

        guard !paneBounds.isEmpty else {
            return paneIds.sorted { $0.id.uuidString < $1.id.uuidString }.first
        }

        let epsilon = 0.000_1
        let rightMostX = paneBounds.values.map(\.maxX).max() ?? 0

        let sortedCandidates = paneBounds
            .filter { _, rect in abs(rect.maxX - rightMostX) <= epsilon }
            .sorted { lhs, rhs in
                if abs(lhs.value.minY - rhs.value.minY) > epsilon {
                    return lhs.value.minY < rhs.value.minY
                }
                if abs(lhs.value.minX - rhs.value.minX) > epsilon {
                    return lhs.value.minX > rhs.value.minX
                }
                return lhs.key < rhs.key
            }

        for candidate in sortedCandidates {
            if let pane = paneById[candidate.key] {
                return pane
            }
        }

        return paneIds.sorted { $0.id.uuidString < $1.id.uuidString }.first
    }

    private enum BrowserPaneBranch {
        case first
        case second
    }

    private struct BrowserPaneBreadcrumb {
        let split: ExternalSplitNode
        let branch: BrowserPaneBranch
    }

    private func browserPathToPane(targetPaneId: String, node: ExternalTreeNode) -> [BrowserPaneBreadcrumb]? {
        switch node {
        case .pane(let paneNode):
            return paneNode.id == targetPaneId ? [] : nil
        case .split(let splitNode):
            if var path = browserPathToPane(targetPaneId: targetPaneId, node: splitNode.first) {
                path.append(BrowserPaneBreadcrumb(split: splitNode, branch: .first))
                return path
            }
            if var path = browserPathToPane(targetPaneId: targetPaneId, node: splitNode.second) {
                path.append(BrowserPaneBreadcrumb(split: splitNode, branch: .second))
                return path
            }
            return nil
        }
    }

    private func browserCollectPaneNodes(node: ExternalTreeNode, into output: inout [ExternalPaneNode]) {
        switch node {
        case .pane(let paneNode):
            output.append(paneNode)
        case .split(let splitNode):
            browserCollectPaneNodes(node: splitNode.first, into: &output)
            browserCollectPaneNodes(node: splitNode.second, into: &output)
        }
    }

    private func browserCollectNormalizedPaneBounds(
        node: ExternalTreeNode,
        availableRect: CGRect,
        into output: inout [String: CGRect]
    ) {
        switch node {
        case .pane(let paneNode):
            output[paneNode.id] = availableRect
        case .split(let splitNode):
            let divider = min(max(splitNode.dividerPosition, 0), 1)
            let firstRect: CGRect
            let secondRect: CGRect

            if splitNode.orientation.lowercased() == "vertical" {
                // Stacked split: first = top, second = bottom
                firstRect = CGRect(
                    x: availableRect.minX,
                    y: availableRect.minY,
                    width: availableRect.width,
                    height: availableRect.height * divider
                )
                secondRect = CGRect(
                    x: availableRect.minX,
                    y: availableRect.minY + (availableRect.height * divider),
                    width: availableRect.width,
                    height: availableRect.height * (1 - divider)
                )
            } else {
                // Side-by-side split: first = left, second = right
                firstRect = CGRect(
                    x: availableRect.minX,
                    y: availableRect.minY,
                    width: availableRect.width * divider,
                    height: availableRect.height
                )
                secondRect = CGRect(
                    x: availableRect.minX + (availableRect.width * divider),
                    y: availableRect.minY,
                    width: availableRect.width * (1 - divider),
                    height: availableRect.height
                )
            }

            browserCollectNormalizedPaneBounds(node: splitNode.first, availableRect: firstRect, into: &output)
            browserCollectNormalizedPaneBounds(node: splitNode.second, availableRect: secondRect, into: &output)
        }
    }

    private struct BrowserCloseFallbackPlan {
        let orientation: SplitOrientation
        let insertFirst: Bool
        let anchorPaneId: UUID?
    }

    private func stageClosedBrowserRestoreSnapshotIfNeeded(for tab: Bonsplit.Tab, inPane pane: PaneID) {
        guard !suppressClosedPanelHistory else {
            pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tab.id)
            return
        }
        guard let panelId = panelIdFromSurfaceId(tab.id),
              let browserPanel = browserPanel(for: panelId),
              let tabIndex = bonsplitController.tabs(inPane: pane).firstIndex(where: { $0.id == tab.id }) else {
            pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tab.id)
            return
        }

        let fallbackPlan = browserCloseFallbackPlan(
            forPaneId: pane.id.uuidString,
            in: bonsplitController.treeSnapshot()
        )
        let resolvedURL = browserPanel.currentURL
            ?? browserPanel.preferredURLStringForOmnibar().flatMap(URL.init(string:))
        guard !browserIsTemporaryHistoryURL(resolvedURL) else {
            pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tab.id)
            return
        }

        pendingClosedBrowserRestoreSnapshots[tab.id] = ClosedBrowserPanelRestoreSnapshot(
            workspaceId: id,
            url: resolvedURL,
            profileID: browserPanel.profileID,
            originalPaneId: pane.id,
            originalTabIndex: tabIndex,
            fallbackSplitOrientation: fallbackPlan?.orientation,
            fallbackSplitInsertFirst: fallbackPlan?.insertFirst ?? false,
            fallbackAnchorPaneId: fallbackPlan?.anchorPaneId
        )
    }

    private func clearStagedClosedBrowserRestoreSnapshot(for tabId: TabID) {
        pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tabId)
    }

    private func browserCloseFallbackPlan(
        forPaneId targetPaneId: String,
        in node: ExternalTreeNode
    ) -> BrowserCloseFallbackPlan? {
        switch node {
        case .pane:
            return nil
        case .split(let splitNode):
            if case .pane(let firstPane) = splitNode.first, firstPane.id == targetPaneId {
                return BrowserCloseFallbackPlan(
                    orientation: splitNode.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                    insertFirst: true,
                    anchorPaneId: browserNearestPaneId(
                        in: splitNode.second,
                        targetCenter: browserPaneCenter(firstPane)
                    )
                )
            }

            if case .pane(let secondPane) = splitNode.second, secondPane.id == targetPaneId {
                return BrowserCloseFallbackPlan(
                    orientation: splitNode.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                    insertFirst: false,
                    anchorPaneId: browserNearestPaneId(
                        in: splitNode.first,
                        targetCenter: browserPaneCenter(secondPane)
                    )
                )
            }

            if let nested = browserCloseFallbackPlan(forPaneId: targetPaneId, in: splitNode.first) {
                return nested
            }
            return browserCloseFallbackPlan(forPaneId: targetPaneId, in: splitNode.second)
        }
    }

    private func browserPaneCenter(_ pane: ExternalPaneNode) -> (x: Double, y: Double) {
        (
            x: pane.frame.x + (pane.frame.width * 0.5),
            y: pane.frame.y + (pane.frame.height * 0.5)
        )
    }

    private func browserNearestPaneId(
        in node: ExternalTreeNode,
        targetCenter: (x: Double, y: Double)?
    ) -> UUID? {
        var panes: [ExternalPaneNode] = []
        browserCollectPaneNodes(node: node, into: &panes)
        guard !panes.isEmpty else { return nil }

        let bestPane: ExternalPaneNode?
        if let targetCenter {
            bestPane = panes.min { lhs, rhs in
                let lhsCenter = browserPaneCenter(lhs)
                let rhsCenter = browserPaneCenter(rhs)
                let lhsDistance = pow(lhsCenter.x - targetCenter.x, 2) + pow(lhsCenter.y - targetCenter.y, 2)
                let rhsDistance = pow(rhsCenter.x - targetCenter.x, 2) + pow(rhsCenter.y - targetCenter.y, 2)
                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }
                return lhs.id < rhs.id
            }
        } else {
            bestPane = panes.first
        }

        guard let bestPane else { return nil }
        return UUID(uuidString: bestPane.id)
    }

    @discardableResult
    func moveSurface(panelId: UUID, toPane paneId: PaneID, atIndex index: Int? = nil, focus: Bool = true) -> Bool {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return false }
        guard bonsplitController.allPaneIds.contains(paneId) else { return false }
        guard bonsplitController.moveTab(tabId, toPane: paneId, atIndex: index) else { return false }

        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(tabId)
            focusPanel(panelId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()
        return true
    }

    @discardableResult
    private func moveSurfaceToAdjacentPane(panelId: UUID, direction: NavigationDirection) -> Bool {
        guard panels[panelId] != nil,
              let sourcePaneId = paneId(forPanelId: panelId),
              let targetPaneId = bonsplitController.adjacentPane(to: sourcePaneId, direction: direction) else {
            return false
        }
        return moveSurface(panelId: panelId, toPane: targetPaneId, focus: true)
    }

    @discardableResult
    func reorderSurface(panelId: UUID, toIndex index: Int, focus: Bool = true) -> Bool {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return false }
        guard bonsplitController.reorderTab(tabId, toIndex: index) else { return false }

        if focus, let paneId = paneId(forPanelId: panelId) {
            applyTabSelection(tabId: tabId, inPane: paneId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()
        return true
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
        // All mirror tabs must live in a single pane: a global tmux window order
        // can't be expressed across a user-arranged split. If the requested panels
        // resolve to more than one pane (or none), skip rather than reorder a
        // subset of one pane.
        let presentPaneIds = Set(panelOrder.compactMap { paneId(forPanelId: $0) })
        guard presentPaneIds.count == 1, let paneId = presentPaneIds.first else { return false }
        let currentPanelIds = bonsplitController.tabs(inPane: paneId).compactMap { panelIdFromSurfaceId($0.id) }
        guard let desired = RemoteTmuxSessionMirror.mirrorTabReorder(current: currentPanelIds, requested: panelOrder) else { return false }
#if DEBUG
        cmuxDebugLog("remote-tmux: reorder mirror tabs ws=\(id.uuidString.prefix(5)) count=\(desired.count)")
#endif

        let savedSelectedTabId = bonsplitController.selectedTab(inPane: paneId)?.id
        let savedFocusedPaneId = bonsplitController.focusedPaneId

        isApplyingRemoteTmuxTabReorder = true
        defer { isApplyingRemoteTmuxTabReorder = false }
        for (index, panelId) in desired.enumerated() {
            guard let tabId = surfaceIdFromPanelId(panelId) else { continue }
            _ = bonsplitController.reorderTab(tabId, toIndex: index)
        }
        // Restore bonsplit's internal selection + focus (the loop moved them to the
        // last-reordered tab). cmux's own focus/selection were never touched (the
        // delegate handlers short-circuited), so this just realigns bonsplit with
        // the user's unchanged state — no `applyTabSelection` runs.
        if let savedSelectedTabId { bonsplitController.selectTab(savedSelectedTabId) }
        if let savedFocusedPaneId { bonsplitController.focusPane(savedFocusedPaneId) }

        scheduleTerminalGeometryReconcile()
        return true
    }

    func detachSurface(panelId: UUID) -> DetachedSurfaceTransfer? {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return nil }
        guard let sourcePanel = panels[panelId] else { return nil }
        let sourcePaneId = paneId(forPanelId: panelId)
        let shouldSkipControlMasterCleanupAfterDetach =
            activeRemoteTerminalSurfaceIds.contains(panelId)
            && activeRemoteTerminalSurfaceIds.count == 1
#if DEBUG
        let detachStart = ProcessInfo.processInfo.systemUptime
        cmuxDebugLog(
            "split.detach.begin ws=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "tab=\(tabId.uuid.uuidString.prefix(5)) activeDetachTxn=\(activeDetachCloseTransactions) " +
            "pendingDetached=\(pendingDetachedSurfaces.count)"
        )
#endif

        splitLayout.markDetaching(tabId)
        forceCloseTabIds.insert(tabId)
        splitLayout.openDetachCloseTransaction()
        defer { splitLayout.closeDetachCloseTransaction() }
        guard bonsplitController.closeTab(tabId) else {
            splitLayout.cancelDetach(tabId)
            forceCloseTabIds.remove(tabId)
#if DEBUG
            cmuxDebugLog(
                "split.detach.fail ws=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
                "tab=\(tabId.uuid.uuidString.prefix(5)) reason=closeTabRejected elapsedMs=\(debugElapsedMs(since: detachStart))"
            )
#endif
            return nil
        }

        var detached = splitLayout.takeDetachedTransfer(tabId)
        if shouldSkipControlMasterCleanupAfterDetach, let detachedTransfer = detached, detachedTransfer.isRemoteTerminal {
            skipControlMasterCleanupAfterDetachedRemoteTransfer = true
            if detachedTransfer.remoteCleanupConfiguration == nil {
                detached = detachedTransfer.withRemoteCleanupConfiguration(remoteConfiguration)
            }
        }
        publishCmuxSurfaceClosed(panelId, paneId: sourcePaneId, panel: sourcePanel, origin: detached == nil ? "detach_lost" : "detach")
#if DEBUG
        cmuxDebugLog(
            "split.detach.end ws=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "tab=\(tabId.uuid.uuidString.prefix(5)) transfer=\(detached != nil ? 1 : 0) " +
            "elapsedMs=\(debugElapsedMs(since: detachStart))"
        )
#endif
        return detached
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
        let detachedBrowserPlayingAudio = (detached.panel as? BrowserPanel)?.isPlayingAudio ?? false

        guard let newTabId = bonsplitController.createTab(
            title: detached.title,
            hasCustomTitle: detached.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            icon: detached.icon,
            iconImageData: detached.iconImageData,
            kind: detached.kind,
            isDirty: detached.panel.isDirty,
            isLoading: detached.isLoading,
            isAudioMuted: detachedBrowserMuted,
            isAudioPlaying: detachedBrowserPlayingAudio,
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
            discardBrowserPanelSubscription(panelId: detached.panelId, panel: detached.panel)
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

        bindSurface(newTabId, toPanelId: detached.panelId)
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
        } else if let customSidebarPanel = detached.panel as? CustomSidebarPanel {
            customSidebarPanel.reattach(to: self)
        }
        AppDelegate.shared?.notificationStore?.rebindSurfaceNotifications(
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
            remotePTYSessionIDsByPanelId[detached.panelId] = remotePTYSessionID
        } else {
            remotePTYSessionIDsByPanelId.removeValue(forKey: detached.panelId)
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

    func preserveFocusAfterNonFocusSplit(
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
        AppDelegate.shared?.focusLog.append(
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
                pendingReparentFocusSuppressionViews.values.contains { $0 === hostedView }
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
        guard let app = AppDelegate.shared else {
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

    // MARK: - Context Menu Shortcuts

    static func buildContextMenuShortcuts() -> [TabContextAction: KeyboardShortcut] {
        var shortcuts: [TabContextAction: KeyboardShortcut] = [:]
        let mappings: [(TabContextAction, KeyboardShortcutSettings.Action)] = [
            (.rename, .renameTab),
            (.toggleZoom, .toggleSplitZoom),
            (.newTerminalToRight, .newSurface),
        ]
        for (contextAction, settingsAction) in mappings {
            let stored = KeyboardShortcutSettings.shortcut(for: settingsAction)
            if let key = stored.keyEquivalent {
                shortcuts[contextAction] = KeyboardShortcut(key, modifiers: stored.eventModifiers)
            }
        }
        return shortcuts
    }

    private func copyIdentifiersToPasteboard(surfaceId: UUID) {
        let paneId = paneId(forPanelId: surfaceId)?.id
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makeWorkspacePaneSurfaceIdentifiers(
                workspaceId: id,
                paneId: paneId,
                surfaceId: surfaceId,
                includeRefs: true
            )
        )
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

    func setPortalRenderingEnabled(_ enabled: Bool, reason: String) {
        let changed = portalRenderingEnabled != enabled
        portalRenderingEnabled = enabled
        if enabled {
            if changed {
                beginEventDrivenLayoutFollowUp(
                    reason: reason,
                    includeGeometry: true
                )
            }
        } else {
            clearLayoutFollowUp()
            hideAllTerminalPortalViews()
            hideAllBrowserPortalViews()
        }
    }

    func setAgentHibernationAutoResumePresentationVisible(_ isVisible: Bool) {
        guard agentHibernationAutoResumePresentationVisible != isVisible else { return }
        agentHibernationAutoResumePresentationVisible = isVisible
        guard isVisible else { return }
        reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
    }

    // MARK: - Utility

    /// Writes a small shell wrapper that keeps a disconnected remote terminal visible.
    /// Returned path goes to `initialCommand`, which Ghostty runs as the PTY command.
    private static func remoteDisconnectPlaceholderScript(target: String, reconnectCommand: String?) -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent(
            "cmux-remote-disconnect-\(UUID().uuidString.lowercased()).sh"
        )
        // Encode the target as base64 and decode it inside the shell. This sidesteps every
        // layer of shell quoting: no matter what the target contains (`$(id)`, backticks,
        // single/double quotes, escape sequences), the shell never sees it as shell syntax.
        // Previous version only escaped backslash and double-quote, which left command
        // substitution and backticks as a live injection vector (Codex P2).
        let encodedTarget = Data(target.utf8).base64EncodedString()
        // Localized banner strings. Both use %s (not %@) because they're rendered by the
        // POSIX printf inside the shell wrapper, not by Swift's String(format:).
        let endedLineFormat = String(
            localized: "remote.disconnectBanner.sessionEnded",
            defaultValue: "[cmux] remote session disconnected: %s"
        )
        let reconnectLine = String(
            localized: "remote.disconnectBanner.reconnectHint",
            defaultValue: "[cmux] Press Enter to reconnect. This terminal will stay disconnected until then."
        )
        let reconnectUnavailableLine = String(
            localized: "remote.disconnectBanner.reconnectUnavailableHint",
            defaultValue: "[cmux] Reconnect this workspace from the sidebar or by running the original cmux remote command again."
        )
        // Encode the localized lines the same way as the target, so a translator using
        // backticks or $(…) in a translation string can't unexpectedly execute in the
        // user's local shell. Decoded inline at wrapper startup, then fed to printf.
        let encodedEndedFormat = Data(endedLineFormat.utf8).base64EncodedString()
        let encodedReconnectLine = Data(reconnectLine.utf8).base64EncodedString()
        let encodedReconnectUnavailableLine = Data(reconnectUnavailableLine.utf8).base64EncodedString()
        let encodedReconnectCommand = Data((reconnectCommand ?? "").utf8).base64EncodedString()
        let body = """
        #!/bin/sh
        cmux_disconnect_decode() {
          printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null
        }
        cmux_disconnect_target="$(cmux_disconnect_decode '\(encodedTarget)')"
        cmux_disconnect_ended_format="$(cmux_disconnect_decode '\(encodedEndedFormat)')"
        cmux_disconnect_reconnect_line="$(cmux_disconnect_decode '\(encodedReconnectLine)')"
        cmux_disconnect_reconnect_unavailable_line="$(cmux_disconnect_decode '\(encodedReconnectUnavailableLine)')"
        cmux_disconnect_reconnect_command="$(cmux_disconnect_decode '\(encodedReconnectCommand)')"
        # Append newline + color codes ourselves rather than trusting the translator to
        # preserve them in every locale.
        printf '\\033[1;33m'
        printf "$cmux_disconnect_ended_format" "$cmux_disconnect_target"
        printf '\\033[0m\\n' >&2
        # Remove ourselves so /tmp doesn't accumulate these wrappers across sessions.
        rm -f -- "$0" 2>/dev/null || true
        if [ -n "$cmux_disconnect_reconnect_command" ]; then
          printf '\\033[2m%s\\033[0m\\n\\n' "$cmux_disconnect_reconnect_line" >&2
          IFS= read -r _ || exit 0
          cmux_reconnect_cli="${CMUX_BUNDLED_CLI_PATH:-}"
          if [ -z "$cmux_reconnect_cli" ] || [ ! -x "$cmux_reconnect_cli" ]; then
            cmux_reconnect_cli="$(command -v cmux 2>/dev/null || true)"
          fi
          cmux_reconnect_socket="${CMUX_SOCKET_PATH:-${CMUX_SOCKET:-}}"
          if [ -n "$cmux_reconnect_cli" ] && [ -n "$cmux_reconnect_socket" ] && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
            cmux_reconnect_payload="{\\"workspace_id\\":\\"$CMUX_WORKSPACE_ID\\""
            if [ -n "${CMUX_SURFACE_ID:-}" ]; then
              cmux_reconnect_payload="$cmux_reconnect_payload,\\"surface_id\\":\\"$CMUX_SURFACE_ID\\""
            fi
            cmux_reconnect_payload="$cmux_reconnect_payload}"
            if "$cmux_reconnect_cli" --socket "$cmux_reconnect_socket" rpc workspace.remote.reconnect "$cmux_reconnect_payload" >/dev/null 2>&1; then
              exec /bin/sh -lc "$cmux_disconnect_reconnect_command"
            fi
          fi
          printf '\\033[2m%s\\033[0m\\n' "$cmux_disconnect_reconnect_unavailable_line" >&2
          while IFS= read -r _; do :; done
          exit 0
        fi
        printf '\\033[2m%s\\033[0m\\n' "$cmux_disconnect_reconnect_unavailable_line" >&2
        while IFS= read -r _; do :; done
        exit 0

        """
        do {
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return scriptURL.path
        } catch {
            return "/bin/sh"
        }
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
            Self.remoteDisconnectPlaceholderScript(
                target: $0.target,
                reconnectCommand: $0.reconnectCommand
            )
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
            bindSurface(newTabId, toPanelId: newPanel.id)
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
        guard portalRenderingEnabled else { return }
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
    private func scheduleFocusReconcile() {
        guard portalRenderingEnabled else { return }
#if DEBUG
        if isDetachingCloseTransaction {
            debugFocusReconcileScheduledDuringDetachCount += 1
        }
#endif
        guard !focusReconcileScheduled else { return }
        focusReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.portalRenderingEnabled else {
                self.focusReconcileScheduled = false
                return
            }
            self.focusReconcileScheduled = false
            self.reconcileFocusState()
        }
    }

    private func beginEventDrivenLayoutFollowUp(
        reason: String,
        browserPanelId: UUID? = nil,
        browserExitFocusPanelId: UUID? = nil,
        terminalFocusPanelId: UUID? = nil,
        includeGeometry: Bool = false
    ) {
        guard portalRenderingEnabled else { return }
        layoutFollowUpReason = reason
        if let browserPanelId {
            layoutFollowUpBrowserPanelId = browserPanelId
        }
        if let browserExitFocusPanelId {
            layoutFollowUpBrowserExitFocusPanelId = browserExitFocusPanelId
        }
        if let terminalFocusPanelId {
            layoutFollowUpTerminalFocusPanelId = terminalFocusPanelId
        }
        layoutFollowUpNeedsGeometryPass = layoutFollowUpNeedsGeometryPass || includeGeometry
        layoutFollowUpStalledAttemptCount = 0
        // Invalidate any pending retry whose delay was computed from a stale stall count.
        // Incrementing the version causes old closures to exit early; clearing the flag
        // allows scheduleLayoutFollowUpAttempt() below to enqueue a fresh asyncAfter(0).
        layoutFollowUpAttemptVersion &+= 1
        layoutFollowUpAttemptScheduled = false

        if layoutFollowUpTimeoutWorkItem == nil {
            installLayoutFollowUpObservers()
        }
        refreshLayoutFollowUpTimeout()
        // Use async scheduling instead of a synchronous call here. beginEventDrivenLayoutFollowUp
        // is often invoked from splitTabBar(_:didChangeGeometry:), which fires from inside
        // SwiftUI's .onChange(of: geometry) during an active layout pass. Calling
        // attemptEventDrivenLayoutFollowUp() synchronously in that context causes
        // flushWorkspaceWindowLayouts() → displayIfNeeded() to be called re-entrantly,
        // incrementing AppKit's per-window constraint-pass counter on every display cycle
        // until it exceeds the limit and crashes with NSGenericException.
        // scheduleLayoutFollowUpAttempt() defers via asyncAfter(0) so the flush always
        // happens after the current layout pass completes.
        scheduleLayoutFollowUpAttempt()
    }

    func suppressReparentFocusUntilLayoutFollowUp(
        _ hostedView: GhosttySurfaceScrollView?,
        reason: String
    ) {
        guard let hostedView else { return }
        hostedView.suppressReparentFocus()
        pendingReparentFocusSuppressionViews[ObjectIdentifier(hostedView)] = hostedView
#if DEBUG
        cmuxDebugLog("focus.reparent.suppressPending reason=\(reason) count=\(pendingReparentFocusSuppressionViews.count)")
#endif

        guard portalRenderingEnabled else {
            clearPendingReparentFocusSuppressions(reason: "\(reason).portalDisabled")
            return
        }

        beginEventDrivenLayoutFollowUp(reason: reason, includeGeometry: true)
    }

    private func clearPendingReparentFocusSuppressions(reason: String) {
        guard !pendingReparentFocusSuppressionViews.isEmpty else { return }
        let hostedViews = Array(pendingReparentFocusSuppressionViews.values)
        pendingReparentFocusSuppressionViews.removeAll()
#if DEBUG
        cmuxDebugLog("focus.reparent.clearPending reason=\(reason) count=\(hostedViews.count)")
#endif
        for hostedView in hostedViews {
            hostedView.clearSuppressReparentFocus()
        }
    }

    private func clearReadyPendingReparentFocusSuppressions(reason: String) {
        guard !pendingReparentFocusSuppressionViews.isEmpty else { return }
        let readyKeys = pendingReparentFocusSuppressionViews.compactMap { key, hostedView in
            hostedView.canClearPendingReparentFocusSuppressionAfterLayoutAttempt() ? key : nil
        }
        guard !readyKeys.isEmpty else { return }
        let hostedViews = readyKeys.compactMap { pendingReparentFocusSuppressionViews[$0] }
        for key in readyKeys {
            pendingReparentFocusSuppressionViews.removeValue(forKey: key)
        }
#if DEBUG
        cmuxDebugLog("focus.reparent.clearReady reason=\(reason) count=\(hostedViews.count)")
#endif
        for hostedView in hostedViews {
            hostedView.clearSuppressReparentFocus()
        }
    }

#if DEBUG
    func debugBeginReparentFocusSuppressionForTesting(_ hostedView: GhosttySurfaceScrollView, reason: String) {
        suppressReparentFocusUntilLayoutFollowUp(hostedView, reason: reason)
    }

    func debugAttemptEventDrivenLayoutFollowUpForTesting() {
        attemptEventDrivenLayoutFollowUp()
    }

    func debugHasPendingReparentFocusSuppressionsForTesting() -> Bool {
        !pendingReparentFocusSuppressionViews.isEmpty
    }
#endif

    private func installLayoutFollowUpObservers() {
        guard layoutFollowUpTimeoutWorkItem == nil else { return }

        let enqueueAttempt: () -> Void = { [weak self] in
            self?.scheduleLayoutFollowUpAttempt()
        }

        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceHostedViewDidMoveToWindow,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalPortalVisibilityDidChange,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .browserPortalRegistryDidChange,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidBecomeFirstResponderSurface,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .browserDidBecomeFirstResponderWebView,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpPanelsCancellable = panelsPublisher
            .map { _ in () }
            .sink { _ in
                enqueueAttempt()
            }
    }

    private func refreshLayoutFollowUpTimeout() {
        layoutFollowUpTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.clearLayoutFollowUp()
        }
        layoutFollowUpTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func clearLayoutFollowUp() {
        clearPendingReparentFocusSuppressions(reason: "workspace.layoutFollowUpEnd")
        layoutFollowUpTimeoutWorkItem?.cancel()
        layoutFollowUpTimeoutWorkItem = nil
        layoutFollowUpObservers.forEach { NotificationCenter.default.removeObserver($0) }
        layoutFollowUpObservers.removeAll()
        layoutFollowUpPanelsCancellable?.cancel()
        layoutFollowUpPanelsCancellable = nil
        layoutFollowUpReason = nil
        layoutFollowUpTerminalFocusPanelId = nil
        layoutFollowUpBrowserPanelId = nil
        layoutFollowUpBrowserExitFocusPanelId = nil
        layoutFollowUpNeedsGeometryPass = false
        layoutFollowUpAttemptVersion &+= 1
        layoutFollowUpAttemptScheduled = false
        layoutFollowUpStalledAttemptCount = 0
    }

    private func scheduleLayoutFollowUpAttempt() {
        guard portalRenderingEnabled else { return }
        guard layoutFollowUpTimeoutWorkItem != nil else { return }
        guard !layoutFollowUpAttemptScheduled else { return }

        layoutFollowUpAttemptScheduled = true
        let delay = layoutFollowUpBackoffDelay()
        let version = layoutFollowUpAttemptVersion
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.layoutFollowUpAttemptVersion == version else { return }
            guard self.portalRenderingEnabled else {
                self.layoutFollowUpAttemptScheduled = false
                self.clearLayoutFollowUp()
                return
            }
            self.layoutFollowUpAttemptScheduled = false
            self.attemptEventDrivenLayoutFollowUp()
        }
    }

    private func layoutFollowUpBackoffDelay() -> TimeInterval {
        guard layoutFollowUpStalledAttemptCount > 0 else { return 0 }
        let baseDelay: TimeInterval = 0.01
        let exponent = min(layoutFollowUpStalledAttemptCount - 1, 5)
        return min(0.25, baseDelay * pow(2.0, Double(exponent)))
    }

    private func flushWorkspaceWindowLayouts() {
        for window in NSApp.windows where window.isVisible {
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func browserPortalAnchorReady(for browserPanel: BrowserPanel) -> Bool {
        let anchorView = browserPanel.portalAnchorView
        return
            anchorView.window != nil &&
            anchorView.superview != nil &&
            anchorView.bounds.width > 1 &&
            anchorView.bounds.height > 1
    }

    private func browserPortalReady(for browserPanel: BrowserPanel) -> Bool {
        browserPortalAnchorReady(for: browserPanel) &&
            browserPanel.webView.window != nil &&
            browserPanel.webView.superview != nil &&
            BrowserWindowPortalRegistry.isWebView(browserPanel.webView, boundTo: browserPanel.portalAnchorView)
    }

    private func browserSplitZoomExitFocusNeedsFollowUp(panelId: UUID) -> Bool {
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

    private func terminalFocusNeedsFollowUp() -> Bool {
        guard let panelId = layoutFollowUpTerminalFocusPanelId,
              let terminalPanel = terminalPanel(for: panelId) else {
            return false
        }
        return focusedPanelId != panelId || !terminalPanel.hostedView.isSurfaceViewFirstResponder()
    }

    private func browserPanelNeedsFollowUp() -> Bool {
        guard let panelId = layoutFollowUpBrowserPanelId,
              let browserPanel = browserPanel(for: panelId) else {
            return false
        }
        return !browserPortalReady(for: browserPanel)
    }

    private func attemptEventDrivenLayoutFollowUp() {
        guard layoutFollowUpTimeoutWorkItem != nil, !isAttemptingLayoutFollowUp else { return }
        guard portalRenderingEnabled else {
            clearLayoutFollowUp()
            hideAllTerminalPortalViews()
            hideAllBrowserPortalViews()
            return
        }
        isAttemptingLayoutFollowUp = true
        defer { isAttemptingLayoutFollowUp = false }

        flushWorkspaceWindowLayouts()

        let geometryPendingBefore = layoutFollowUpNeedsGeometryPass
        let terminalPortalPendingBefore = terminalPortalVisibilityNeedsFollowUp()
        let browserVisibilityPendingBefore = browserPortalVisibilityNeedsFollowUp()
        let terminalFocusPendingBefore = terminalFocusNeedsFollowUp()
        let browserPanelPendingBefore = browserPanelNeedsFollowUp()
        let browserExitPendingBefore = layoutFollowUpBrowserExitFocusPanelId != nil
        let reparentFocusPendingBefore = !pendingReparentFocusSuppressionViews.isEmpty

        if layoutFollowUpNeedsGeometryPass {
            layoutFollowUpNeedsGeometryPass = reconcileTerminalGeometryPass()
        }

        if let terminalFocusPanelId = layoutFollowUpTerminalFocusPanelId {
            if let terminalPanel = terminalPanel(for: terminalFocusPanelId),
               focusedPanelId == terminalFocusPanelId {
                terminalPanel.hostedView.ensureFocus(for: id, surfaceId: terminalFocusPanelId)
                if terminalPanel.hostedView.isSurfaceViewFirstResponder() {
                    layoutFollowUpTerminalFocusPanelId = nil
                }
            } else if terminalPanel(for: terminalFocusPanelId) == nil {
                layoutFollowUpTerminalFocusPanelId = nil
            }
        }

        reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
        let terminalPortalPending = terminalPortalVisibilityNeedsFollowUp()
        clearReadyPendingReparentFocusSuppressions(reason: "workspace.layoutAttempt")
        let reparentFocusPending = !pendingReparentFocusSuppressionViews.isEmpty

        let reason = layoutFollowUpReason ?? "workspace.layout"
        reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason: reason)
        let browserVisibilityPending = browserPortalVisibilityNeedsFollowUp()

        if let browserPanelId = layoutFollowUpBrowserPanelId {
            if let browserPanel = browserPanel(for: browserPanelId) {
                let anchorReady = browserPortalAnchorReady(for: browserPanel)
                let wasReady = browserPortalReady(for: browserPanel)
                if anchorReady && !wasReady {
                    BrowserWindowPortalRegistry.synchronizeForAnchor(browserPanel.portalAnchorView)
                }
                let isReady = browserPortalReady(for: browserPanel)
                if isReady,
                   (!wasReady || BrowserWindowPortalRegistry.debugSnapshot(for: browserPanel.webView)?.containerHidden == true) {
                    BrowserWindowPortalRegistry.refresh(
                        webView: browserPanel.webView,
                        reason: reason
                    )
                }
                if isReady {
                    layoutFollowUpBrowserPanelId = nil
                }
            } else {
                layoutFollowUpBrowserPanelId = nil
            }
        }

        if let browserExitFocusPanelId = layoutFollowUpBrowserExitFocusPanelId {
            if browserSplitZoomExitFocusNeedsFollowUp(panelId: browserExitFocusPanelId) {
                if browserPanel(for: browserExitFocusPanelId) != nil {
                    focusPanel(browserExitFocusPanelId)
                    scheduleFocusReconcile()
                } else {
                    layoutFollowUpBrowserExitFocusPanelId = nil
                }
            } else {
                layoutFollowUpBrowserExitFocusPanelId = nil
            }
        }

        let terminalFocusPending = terminalFocusNeedsFollowUp()
        let browserPanelPending = browserPanelNeedsFollowUp()
        let browserExitPending = layoutFollowUpBrowserExitFocusPanelId != nil
        let needsMoreWork =
            layoutFollowUpNeedsGeometryPass ||
            terminalPortalPending ||
            browserVisibilityPending ||
            terminalFocusPending ||
            browserPanelPending ||
            browserExitPending ||
            reparentFocusPending

        if !needsMoreWork {
            clearLayoutFollowUp()
            return
        }

        let didMakeProgress =
            (geometryPendingBefore && !layoutFollowUpNeedsGeometryPass) ||
            (terminalPortalPendingBefore && !terminalPortalPending) ||
            (browserVisibilityPendingBefore && !browserVisibilityPending) ||
            (terminalFocusPendingBefore && !terminalFocusPending) ||
            (browserPanelPendingBefore && !browserPanelPending) ||
            (browserExitPendingBefore && !browserExitPending) ||
            (reparentFocusPendingBefore && !reparentFocusPending)

        if didMakeProgress {
            layoutFollowUpStalledAttemptCount = 0
            scheduleLayoutFollowUpAttempt()
        } else {
            layoutFollowUpStalledAttemptCount += 1
        }
    }

    /// Reconcile remaining terminal view geometries after split topology changes.
    /// This keeps AppKit bounds and Ghostty surface sizes in sync in the next runloop turn.
    private func reconcileTerminalGeometryPass() -> Bool {
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
        beginEventDrivenLayoutFollowUp(
            reason: "workspace.geometry",
            includeGeometry: true
        )
    }

    private func renderedVisiblePanelIdsForCurrentLayout() -> Set<UUID> {
        guard portalRenderingEnabled else { return [] }
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

    func agentHibernationVisiblePanelIdsForCurrentLayout() -> Set<UUID> {
        guard agentHibernationAutoResumePresentationVisible else { return [] }
        return renderedVisiblePanelIdsForCurrentLayout()
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

    private func terminalPortalVisibilityNeedsFollowUp() -> Bool {
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

    private func browserPortalVisibilityNeedsFollowUp() -> Bool {
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

    private func scheduleMovedTerminalRefresh(panelId: UUID) {
        guard terminalPanel(for: panelId) != nil else { return }

        // Force an NSViewRepresentable update after drag/move reparenting. This keeps
        // portal host binding current when a pane auto-closes during tab moves.
        terminalPanel(for: panelId)?.requestViewReattach()

        let runRefreshPass: (TimeInterval) -> Void = { [weak self] delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let self, let panel = self.terminalPanel(for: panelId) else { return }
                panel.hostedView.reconcileGeometryNow()
                if panel.surface.surface != nil {
                    panel.surface.forceRefresh()
                }
                if panel.surface.surface == nil {
                    panel.surface.requestBackgroundSurfaceStartIfNeeded()
                }
            }
        }

        // Run once immediately and once on the next turn so rapid split close/reparent
        // sequences still get a post-layout redraw.
        runRefreshPass(0)
        runRefreshPass(0.03)
    }

    private func closeTabs(_ tabIds: [TabID], skipPinned: Bool = true) { closeTabsFromContextMenu(tabIds, skipPinned: skipPinned) }

    private func tabIdsToLeft(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        surfaceList.surfaceIdsToLeft(of: anchorTabId.uuid, inPaneId: paneId.id).map { TabID(uuid: $0) }
    }

    private func tabIdsToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        surfaceList.surfaceIdsToRight(of: anchorTabId.uuid, inPaneId: paneId.id).map { TabID(uuid: $0) }
    }

    private func tabIdsToCloseOthers(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        surfaceList.surfaceIdsToCloseOthers(of: anchorTabId.uuid, inPaneId: paneId.id).map { TabID(uuid: $0) }
    }

    private func createTerminalToRight(of anchorTabId: TabID, inPane paneId: PaneID) {
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        let sourcePanelId = panelIdFromSurfaceId(anchorTabId)
        guard let newPanel = newTerminalSurface(
            inPane: paneId,
            focus: true,
            inheritWorkingDirectoryFallback: true,
            workingDirectoryFallbackSourcePanelId: sourcePanelId
        ) else { return }
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
    }

    private func createBrowserToRight(of anchorTabId: TabID, inPane paneId: PaneID, url: URL? = nil) {
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        let preferredProfileID = panelIdFromSurfaceId(anchorTabId).flatMap { browserPanel(for: $0)?.profileID }
        guard let newPanel = newBrowserSurface(
            inPane: paneId,
            url: url,
            focus: true,
            preferredProfileID: preferredProfileID
        ) else { return }
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
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

    private func promptRenamePanel(tabId: TabID) {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let panel = panels[panelId] else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "alert.renameTab.title", defaultValue: "Rename Tab")
        alert.informativeText = String(localized: "alert.renameTab.message", defaultValue: "Enter a custom name for this tab.")
        let currentTitle = panelCustomTitles[panelId] ?? panelTitles[panelId] ?? panel.displayTitle
        let input = NSTextField(string: currentTitle)
        input.placeholderString = String(localized: "alert.renameTab.placeholder", defaultValue: "Tab name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.renameTab.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "alert.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        setPanelCustomTitle(panelId: panelId, title: input.stringValue)
    }

    private static let bonsplitMoveNewWorkspaceDestinationId = "new-workspace"
    private static let bonsplitMoveExistingWorkspacePrefix = "workspace:"

    private func bonsplitTabMoveDestinations(for tabId: TabID) -> [TabContextMoveDestination] {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let app = AppDelegate.shared else { return [] }

        let workspaceTargets = app.workspaceMoveTargets(forBonsplitTab: tabId.uuid)
        var destinations: [TabContextMoveDestination] = []
        if app.canMoveSurfaceToNewWorkspace(panelId: panelId) {
            destinations.append(TabContextMoveDestination(
                id: Self.bonsplitMoveNewWorkspaceDestinationId,
                title: String(localized: "command.newWorkspace.title", defaultValue: "New Workspace")
            ))
        }
        destinations.append(contentsOf: workspaceTargets.map { target in
            TabContextMoveDestination(
                id: Self.bonsplitMoveExistingWorkspacePrefix + target.workspaceId.uuidString,
                title: target.label
            )
        })
        return destinations
    }

    @discardableResult
    private func moveBonsplitTab(_ tabId: TabID, toMoveDestination destinationId: String) -> Bool {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let app = AppDelegate.shared else { return false }

        let moved: Bool
        if destinationId == Self.bonsplitMoveNewWorkspaceDestinationId {
            moved = app.moveSurfaceToNewWorkspace(
                panelId: panelId,
                focus: true,
                focusWindow: false
            ) != nil
        } else if destinationId.hasPrefix(Self.bonsplitMoveExistingWorkspacePrefix) {
            let rawWorkspaceId = destinationId.dropFirst(Self.bonsplitMoveExistingWorkspacePrefix.count)
            guard let workspaceId = UUID(uuidString: String(rawWorkspaceId)) else { return false }
            moved = app.moveSurface(
                panelId: panelId,
                toWorkspace: workspaceId,
                focus: true,
                focusWindow: true
            )
        } else {
            moved = false
        }

        if !moved {
            showMoveTabFailureAlert()
        }
        return moved
    }

    private func showMoveTabFailureAlert() {
        let failure = NSAlert()
        failure.alertStyle = .warning
        failure.messageText = String(localized: "alert.moveTab.failed.title", defaultValue: "Move Failed")
        failure.informativeText = String(localized: "alert.moveTab.failed.message", defaultValue: "cmux could not move this tab to the selected destination.")
        failure.addButton(withTitle: String(localized: "alert.ok", defaultValue: "OK"))
        _ = failure.runModal()
    }

    private func handleSessionDrop(
        entry: SessionEntry,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        guard let resumeCommand = entry.resumeCommand else { return false }
        let inputWithReturn = resumeCommand + "\n"
        switch destination {
        case .insert(let paneId, _):
            let panel = newTerminalSurface(
                inPane: paneId,
                focus: true,
                workingDirectory: entry.resumeWorkingDirectory,
                initialInput: inputWithReturn
            )
            return panel != nil
        case .split(let paneId, let orientation, let insertFirst):
            let panel = splitPaneWithNewTerminal(
                targetPane: paneId,
                orientation: orientation,
                insertFirst: insertFirst,
                workingDirectory: entry.resumeWorkingDirectory,
                initialInput: inputWithReturn
            )
            return panel != nil
        }
    }

    func handleFilePreviewDrop(
        entry: FilePreviewDragEntry,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        switch destination {
        case .insert(let paneId, let index):
            return !openFileSurfaces(
                inPane: paneId,
                filePaths: [entry.filePath],
                focus: true,
                targetIndex: index
            ).isEmpty
        case .split(let paneId, let orientation, let insertFirst):
            return splitPaneWithFileSurface(
                targetPane: paneId,
                orientation: orientation,
                insertFirst: insertFirst,
                filePath: entry.filePath
            ) != nil
        }
    }

    func handleExternalFileDrop(_ request: BonsplitController.ExternalFileDropRequest) -> Bool {
        let entries = request.urls
            .filter(\.isFileURL)
            .map {
                FilePreviewDragEntry(
                    filePath: $0.path,
                    displayTitle: $0.lastPathComponent
                )
            }
        guard !entries.isEmpty else { return false }

        switch request.destination {
        case .insert(let paneId, let index):
            return !openFileSurfaces(
                inPane: paneId,
                filePaths: entries.map(\.filePath),
                focus: true,
                targetIndex: index
            ).isEmpty

        case .split(let sourcePaneId, let orientation, let insertFirst):
            guard let first = entries.first,
                  let firstPanel = splitPaneWithFileSurface(
                    targetPane: sourcePaneId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    filePath: first.filePath
                  ) else {
                return false
            }

            let targetPane = paneId(forPanelId: firstPanel.id) ?? sourcePaneId
            _ = openFileSurfaces(
                inPane: targetPane,
                filePaths: entries.dropFirst().map(\.filePath),
                focus: true
            )
            return true
        }
    }

    @discardableResult
    private func splitPaneWithFileSurface(
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
        let requestedRemoteStartupCommand = remoteStartupCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let startupCommand = requestedRemoteStartupCommand?.isEmpty == false ? requestedRemoteStartupCommand : nil
        let effectiveStartupEnvironment = terminalStartupEnvironment(
            base: startupEnvironmentMergingWorkspaceEnvironment([:]),
            remoteStartupCommand: startupCommand
        )
        if startupCommand != nil {
            var template = inheritedConfig ?? CmuxSurfaceConfigTemplate()
            template.waitAfterCommand = true
            inheritedConfig = template
        }

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
        bindSurface(newTab.id, toPanelId: newPanel.id)

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            removeSurfaceMapping(forSurfaceId: newTab.id)
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

    struct AgentConversationForkWorkspaceLaunch: Equatable {
        var workingDirectory: String?
        var terminalWorkingDirectory: String?
        var initialTerminalCommand: String?
        var initialTerminalInput: String
        var initialTerminalEnvironment: [String: String]
        var remoteConfiguration: WorkspaceRemoteConfiguration?
        var autoConnectRemoteConfiguration: Bool
    }

    func forkAgentWorkspaceLaunch(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> AgentConversationForkWorkspaceLaunch? {
        var launchSnapshot = snapshot
        let workingDirectory = forkAgentWorkingDirectory(fromPanelId: panelId, snapshot: snapshot)
        launchSnapshot.workingDirectory = workingDirectory
        let remoteStartupCommand = forkAgentRemoteStartupCommand(fromPanelId: panelId)
        let remoteConfiguration = forkAgentRemoteConfigurationForNewWorkspace(fromPanelId: panelId)
        let isRemoteFork = remoteConfiguration?.terminalStartupCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard panels[panelId] is TerminalPanel,
              let startupInput = launchSnapshot.forkStartupInput(
                  fileManager: fileManager,
                  temporaryDirectory: temporaryDirectory,
                  allowLauncherScript: !isRemoteFork
              ) else {
            return nil
        }

        return AgentConversationForkWorkspaceLaunch(
            workingDirectory: workingDirectory,
            terminalWorkingDirectory: isRemoteFork ? nil : workingDirectory,
            initialTerminalCommand: remoteConfiguration?.terminalStartupCommand ?? remoteStartupCommand,
            initialTerminalInput: startupInput,
            initialTerminalEnvironment: isRemoteFork ? (remoteConfiguration?.sshTerminalStartupEnvironment ?? [:]) : [:],
            remoteConfiguration: remoteConfiguration,
            autoConnectRemoteConfiguration: remoteConfiguration != nil
        )
    }

    @discardableResult
    func forkAgentConversation(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        direction: SplitDirection,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> TerminalPanel? {
        var launchSnapshot = snapshot
        let workingDirectory = forkAgentWorkingDirectory(fromPanelId: panelId, snapshot: snapshot)
        launchSnapshot.workingDirectory = workingDirectory
        let remoteStartupCommand = forkAgentRemoteStartupCommand(fromPanelId: panelId)
        guard panels[panelId] is TerminalPanel,
              let paneId = paneId(forPanelId: panelId),
              let startupInput = launchSnapshot.forkStartupInput(
                  fileManager: fileManager,
                  temporaryDirectory: temporaryDirectory,
                  allowLauncherScript: remoteStartupCommand == nil
              ) else {
            return nil
        }

        let zoomedPaneId = bonsplitController.zoomedPaneId
        if zoomedPaneId != nil {
            clearSplitZoom()
        }
        let forkedPanel = splitPaneWithNewTerminal(
            targetPane: paneId,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            workingDirectory: remoteStartupCommand == nil ? workingDirectory : nil,
            initialInput: startupInput,
            remoteStartupCommand: remoteStartupCommand
        )
        if let forkedPanel,
           remoteStartupCommand != nil,
           let workingDirectory {
            updatePanelDirectory(panelId: forkedPanel.id, directory: workingDirectory)
        }
        if forkedPanel == nil, let zoomedPaneId {
            _ = bonsplitController.togglePaneZoom(inPane: zoomedPaneId)
        }
        return forkedPanel
    }

    func forkAgentWorkingDirectory(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot
    ) -> String? {
        Self.firstNonEmptyPath([
            snapshot.workingDirectory,
            panelDirectories[panelId],
            terminalPanel(for: panelId)?.requestedWorkingDirectory,
            currentDirectory
        ])
    }

    /// Synchronous availability check used by the tab right-click context menu to decide
    /// whether to surface the Fork Conversation item for a given anchor tab. Restricted to
    /// `.supportedWithoutProbe` so we never offer an item that may quietly fail; agents
    /// requiring a probe (e.g. shell-launched OpenCode) stay reachable from the command
    /// palette path that performs that probe first.
    func canForkAgentConversationFromPanel(_ panelId: UUID) -> Bool {
        guard panels[panelId] is TerminalPanel else { return false }
        guard let snapshot = forkableAgentSnapshot(forPanelId: panelId) else {
            return false
        }
        let isRemote = isRemoteTerminalSurface(panelId)
        return ContentView.commandPaletteSnapshotForkAvailability(
            snapshot,
            isRemoteTerminal: isRemote
        ) == .supportedWithoutProbe
    }

    /// Snapshot used by the right-click fork path. Prefers the workspace's restored snapshot
    /// (filled on session restore / hibernation), then falls back to the process-wide
    /// `SharedLiveAgentIndex`. The shared index loads the on-disk hook session store off the
    /// main actor (it runs `sysctl(KERN_PROCARGS2)` per live record for live-PID filtering,
    /// which is too expensive to do synchronously during SwiftUI menu evaluation) and a
    /// single load serves every workspace. The Workspace subscribes to the shared store's
    /// `objectWillChange` in its initializer so that when a refresh lands, this workspace's
    /// own `objectWillChange` fires, ContentView re-renders, and bonsplit's TabBarView re-
    /// evaluates the menu state on the same frame — Fork Conversation appears the moment
    /// the index is loaded without requiring a second right-click.
    func forkableAgentSnapshot(forPanelId panelId: UUID) -> SessionRestorableAgentSnapshot? {
        if let snapshot = restoredAgentSnapshotsByPanelId[panelId] {
            return snapshot
        }
        return SharedLiveAgentIndex.shared.snapshot(workspaceId: id, panelId: panelId)
    }

    /// Fork the panel's agent conversation into a brand-new sibling tab placed immediately
    /// to the right of `anchorTabId` in `paneId`. Uses the same `claude --resume --fork-session`
    /// startup input the existing split/new-workspace forks rely on, so divergence is owned by
    /// the agent itself (Claude / Codex / OpenCode) instead of any cmux-side history copy.
    @discardableResult
    func forkAgentConversationToNewTab(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        anchorTabId: TabID,
        paneId: PaneID,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> TerminalPanel? {
        var launchSnapshot = snapshot
        let workingDirectory = forkAgentWorkingDirectory(fromPanelId: panelId, snapshot: snapshot)
        launchSnapshot.workingDirectory = workingDirectory
        let remoteStartupCommand = forkAgentRemoteStartupCommand(fromPanelId: panelId)
        guard panels[panelId] is TerminalPanel,
              let startupInput = launchSnapshot.forkStartupInput(
                  fileManager: fileManager,
                  temporaryDirectory: temporaryDirectory,
                  allowLauncherScript: remoteStartupCommand == nil
              ) else {
            return nil
        }

        let zoomedPaneId = bonsplitController.zoomedPaneId
        if zoomedPaneId != nil {
            clearSplitZoom()
        }

        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        let forkedPanel = newTerminalSurface(
            inPane: paneId,
            focus: true,
            workingDirectory: remoteStartupCommand == nil ? workingDirectory : nil,
            initialInput: startupInput
        )
        if let forkedPanel {
            _ = reorderSurface(panelId: forkedPanel.id, toIndex: targetIndex)
            if remoteStartupCommand != nil, let workingDirectory {
                updatePanelDirectory(panelId: forkedPanel.id, directory: workingDirectory)
            }
        } else if let zoomedPaneId {
            _ = bonsplitController.togglePaneZoom(inPane: zoomedPaneId)
        }
        return forkedPanel
    }

    private func forkAgentRemoteStartupCommand(fromPanelId panelId: UUID) -> String? {
        guard isRemoteTerminalSurface(panelId) else { return nil }
        return remoteTerminalStartupCommand()
    }

    private func forkAgentRemoteConfigurationForNewWorkspace(fromPanelId panelId: UUID) -> WorkspaceRemoteConfiguration? {
        guard forkAgentRemoteStartupCommand(fromPanelId: panelId) != nil else { return nil }
        let forkedSSHOptions = remoteConfiguration
            .map { WorkspaceRemoteConfiguration.forkedAgentSSHOptions($0.sshOptions) }
        return remoteConfiguration?.sessionSnapshot(sshOptionsOverride: forkedSSHOptions)?.workspaceConfiguration(
            localSocketPath: TerminalController.shared.currentSocketPathForRemoteRestore(),
            allowPersistentPTYRestore: false,
            preserveSSHOptions: true,
            agentSocketPath: remoteConfiguration?.agentSocketPath
        ) ?? remoteConfiguration
    }

    private static func firstNonEmptyPath(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    func handleExternalTabDrop(_ request: BonsplitController.ExternalTabDropRequest) -> Bool {
        // Session-index drag → spawn a brand new terminal at the destination instead
        // of moving an existing tab.
        if let entry = SessionDragRegistry.shared.consume(id: request.tabId.uuid) {
            return handleSessionDrop(entry: entry, destination: request.destination)
        }
        if let entry = FilePreviewDragRegistry.shared.consume(id: request.tabId.uuid) {
            return handleFilePreviewDrop(entry: entry, destination: request.destination)
        }

        guard let app = AppDelegate.shared else { return false }
#if DEBUG
        let dropStart = ProcessInfo.processInfo.systemUptime
#endif

        let targetPane: PaneID
        let targetIndex: Int?
        let splitTarget: (orientation: SplitOrientation, insertFirst: Bool)?
#if DEBUG
        let destinationLabel: String
#endif

        switch request.destination {
        case .insert(let paneId, let index):
            targetPane = paneId
            targetIndex = index
            splitTarget = nil
#if DEBUG
            destinationLabel = "insert pane=\(paneId.id.uuidString.prefix(5)) index=\(index.map(String.init) ?? "nil")"
#endif
        case .split(let paneId, let orientation, let insertFirst):
            targetPane = paneId
            targetIndex = nil
            splitTarget = (orientation, insertFirst)
#if DEBUG
            destinationLabel = "split pane=\(paneId.id.uuidString.prefix(5)) orientation=\(orientation.rawValue) insertFirst=\(insertFirst ? 1 : 0)"
#endif
        }

        #if DEBUG
        cmuxDebugLog(
            "split.externalDrop.begin ws=\(id.uuidString.prefix(5)) tab=\(request.tabId.uuid.uuidString.prefix(5)) " +
            "sourcePane=\(request.sourcePaneId.id.uuidString.prefix(5)) destination=\(destinationLabel)"
        )
        #endif
        let moved = app.moveBonsplitTab(
            tabId: request.tabId.uuid,
            toWorkspace: id,
            targetPane: targetPane,
            targetIndex: targetIndex,
            splitTarget: splitTarget,
            focus: true,
            focusWindow: true
        )
#if DEBUG
        cmuxDebugLog(
            "split.externalDrop.end ws=\(id.uuidString.prefix(5)) tab=\(request.tabId.uuid.uuidString.prefix(5)) " +
            "moved=\(moved ? 1 : 0) elapsedMs=\(debugElapsedMs(since: dropStart))"
        )
#endif
        return moved
    }

}

// MARK: - BonsplitDelegate

// MARK: - PaneTreeHosting (legacy @Published observer hooks)

extension Workspace: PaneTreeHosting {
    /// Legacy `@Published panels` willSet: re-emits objectWillChange and the
    /// Combine bridge at the exact timing `@Published` used.
    func panelsWillChange(to newValue: [UUID: any Panel]) {
        objectWillChange.send()
        setBrowserMediaActivity(
            currentBrowserMediaActivity(panels: newValue),
            invalidateSidebarObservation: false
        )
        panelsPublisher.send(newValue)
    }

    /// Legacy `@Published paneLayoutVersion` willSet; same contract.
    func paneLayoutVersionWillChange(to newValue: Int) {
        objectWillChange.send()
        paneLayoutVersionPublisher.send(newValue)
    }
}

extension Workspace: BonsplitDelegate {
    @MainActor
    private func shouldCloseWorkspaceOnLastSurface(for tabId: TabID, tabStripClose: Bool) -> Bool { lastSurfaceClosePreference(for: tabId).map { tabStripClose ? $0 : true } ?? false }

    private func shouldKeepWorkspaceOpenOnLastSurface(for tabId: TabID, explicitUserClose: Bool, tabStripClose: Bool) -> Bool { (!explicitUserClose || tabStripClose) && lastSurfaceClosePreference(for: tabId) == false }

    private func lastSurfaceClosePreference(for tabId: TabID) -> Bool? {
        let manager = owningTabManager ?? AppDelegate.shared?.tabManagerFor(tabId: id) ?? AppDelegate.shared?.tabManager
        guard panels.count <= 1, panelIdFromSurfaceId(tabId) != nil, let manager,
              manager.tabs.contains(where: { $0.id == id }) else {
            return nil
        }
        return manager.closeWorkspaceOnLastSurfacePreferenceEnabled()
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
            if let nameOverride, !nameOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nameOverride
            }
            guard let panelId = panelIdFromSurfaceId(tabId) else { return nil }
            if let custom = panelCustomTitles[panelId], !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return custom
            }
            if let title = panelTitles[panelId], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return title
            }
            if let dir = panelDirectories[panelId], !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (dir as NSString).lastPathComponent
            }
            return nil
        }()

        let message: String
        if let panelName {
            message = String(localized: "dialog.closeTab.messageNamed", defaultValue: "This will close \"\(panelName)\".")
        } else {
            message = String(localized: "dialog.closeTab.message", defaultValue: "This will close the current tab.")
        }

        if let confirmCloseHandler = (
            owningTabManager
            ?? AppDelegate.shared?.tabManagerFor(tabId: id)
            ?? AppDelegate.shared?.tabManager
        )?.confirmCloseHandler {
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

    private func beginNonFocusSplitFocusReassert(
        preferredPanelId: UUID,
        splitPanelId: UUID
    ) -> UInt64 {
        nonFocusSplitFocusReassertGeneration &+= 1
        let generation = nonFocusSplitFocusReassertGeneration
        pendingNonFocusSplitFocusReassert = PendingNonFocusSplitFocusReassert(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        )
        return generation
    }

    private func matchesPendingNonFocusSplitFocusReassert(
        generation: UInt64,
        preferredPanelId: UUID,
        splitPanelId: UUID
    ) -> Bool {
        guard let pending = pendingNonFocusSplitFocusReassert else { return false }
        return pending.generation == generation &&
            pending.preferredPanelId == preferredPanelId &&
            pending.splitPanelId == splitPanelId
    }

    private func clearNonFocusSplitFocusReassert(generation: UInt64? = nil) {
        guard let pending = pendingNonFocusSplitFocusReassert else { return }
        if let generation, pending.generation != generation { return }
        pendingNonFocusSplitFocusReassert = nil
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
        guard let pending = pendingNonFocusSplitFocusReassert,
              pending.splitPanelId == panelId else {
            return
        }
        pendingNonFocusSplitFocusReassert = nil
    }

    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        func recordPostCloseState() {
            if controller.zoomedPaneId == pane,
               controller.selectedTab(inPane: pane)?.id == tab.id {
                postCloseClearSplitZoomTabIds.insert(tab.id)
            } else {
                postCloseClearSplitZoomTabIds.remove(tab.id)
            }

            let tabs = controller.tabs(inPane: pane)
            guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else {
                postCloseSelectTabId.removeValue(forKey: tab.id)
                return
            }

            let target: TabID? = {
                if idx + 1 < tabs.count { return tabs[idx + 1].id }
                if idx > 0 { return tabs[idx - 1].id }
                return nil
            }()

            if let target {
                postCloseSelectTabId[tab.id] = target
            } else {
                postCloseSelectTabId.removeValue(forKey: tab.id)
            }
        }

        let tabCloseButtonClose = tabStripCloseButtonByTabId.removeValue(forKey: tab.id)
        let tabStripClose = tabCloseButtonClose != nil
        let explicitUserClose = explicitUserCloseTabIds.remove(tab.id) != nil || tabStripClose

        // Remote tmux mirror tab closes route to tmux; tmux reports local removal.
        if isRemoteTmuxMirror, !forceCloseTabIds.contains(tab.id),
           let panelId = panelIdFromSurfaceId(tab.id),
           let remoteTmuxController = AppDelegate.shared?.remoteTmuxController,
           remoteTmuxController.cachedMirrorTabActivity(workspaceId: id, panelId: panelId) != nil {
            let confirmationSource: CloseTabCloseSource =
                tabCloseButtonClose == true ? .tabCloseButton : .shortcut
            if !CloseTabWarningStore(defaults: closeTabWarningDefaults).shouldConfirmClose(
                requiresConfirmation: true, source: confirmationSource
            ) {
                let routed = remoteTmuxController.handleMirrorTabCloseRequested(workspaceId: id, panelId: panelId)
                recordRemoteTmuxWorkspaceCloseAfterWindowClose(routed: routed, tabId: tab.id, panelId: panelId, explicitUserClose: explicitUserClose, tabStripClose: tabStripClose, tabCloseButton: tabCloseButtonClose == true)
                return false
            } else {
                if pendingCloseConfirmTabIds.contains(tab.id) {
                    return false
                }
                let confirmationManager = owningTabManager
                    ?? AppDelegate.shared?.tabManagerFor(tabId: id)
                    ?? AppDelegate.shared?.tabManager
                if let confirmationManager, confirmationManager.isCloseConfirmationInFlight {
                    clearRemoteTmuxWorkspaceCloseIntent(tabId: tab.id)
                    clearCloseHistoryEligibility(tabId: tab.id, panelId: panelId)
                    return false
                }
                pendingCloseConfirmTabIds.insert(tab.id)
                let tabId = tab.id

                let presentConfirmation: @MainActor (String?) -> Void = { [weak self] commandName in
                    guard let self else { return }
                    if let confirmationManager, !confirmationManager.beginCloseConfirmationSession() {
                        self.pendingCloseConfirmTabIds.remove(tabId)
                        self.clearRemoteTmuxWorkspaceCloseIntent(tabId: tabId)
                        self.clearCloseHistoryEligibility(tabId: tabId, panelId: panelId)
                        return
                    }
                    Task { @MainActor in
                        defer {
                            self.pendingCloseConfirmTabIds.remove(tabId)
                            confirmationManager?.endCloseConfirmationSession()
                        }
                        guard self.panelIdFromSurfaceId(tabId) != nil else {
                            self.clearRemoteTmuxWorkspaceCloseIntent(tabId: tabId)
                            self.clearCloseHistoryEligibility(tabId: tabId, panelId: panelId)
                            return
                        }
                        let confirmed = await self.confirmClosePanel(for: tabId, nameOverride: commandName)
                        guard confirmed else {
                            self.clearRemoteTmuxWorkspaceCloseIntent(tabId: tabId)
                            self.clearCloseHistoryEligibility(tabId: tabId, panelId: panelId)
                            return
                        }
                        let routed = remoteTmuxController.handleMirrorTabCloseRequested(
                            workspaceId: self.id, panelId: panelId
                        )
                        self.recordRemoteTmuxWorkspaceCloseAfterWindowClose(routed: routed, tabId: tabId, panelId: panelId, explicitUserClose: explicitUserClose, tabStripClose: tabStripClose, tabCloseButton: tabCloseButtonClose == true)
                    }
                }

                if CloseTabWarningStore(defaults: closeTabWarningDefaults).shouldConfirmClose(
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
                    guard self.panelIdFromSurfaceId(tabId) != nil else {
                        self.pendingCloseConfirmTabIds.remove(tabId)
                        self.clearRemoteTmuxWorkspaceCloseIntent(tabId: tabId)
                        self.clearCloseHistoryEligibility(tabId: tabId, panelId: panelId)
                        return
                    }
                    guard activity.hasActiveCommand else {
                        self.pendingCloseConfirmTabIds.remove(tabId)
                        let routed = remoteTmuxController.handleMirrorTabCloseRequested(
                            workspaceId: self.id, panelId: panelId
                        )
                        self.recordRemoteTmuxWorkspaceCloseAfterWindowClose(routed: routed, tabId: tabId, panelId: panelId, explicitUserClose: explicitUserClose, tabStripClose: tabStripClose, tabCloseButton: tabCloseButtonClose == true)
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
            ?? AppDelegate.shared?.tabManagerFor(tabId: id)
            ?? AppDelegate.shared?.tabManager
        if let closeConfirmationManager, closeConfirmationManager.isCloseConfirmationInFlight {
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

        if explicitUserClose && shouldCloseWorkspaceOnLastSurface(for: tab.id, tabStripClose: tabStripClose) {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            clearCloseHistoryEligibility(tabId: tab.id)
            if tabCloseButtonClose == true {
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
        let confirmationSource: CloseTabCloseSource = tabCloseButtonClose == true ? .tabCloseButton : .shortcut
        if CloseTabWarningStore(defaults: closeTabWarningDefaults).shouldConfirmClose(
            requiresConfirmation: panelNeedsConfirmClose(panelId: panelId),
            source: confirmationSource
        ) {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            if pendingCloseConfirmTabIds.contains(tab.id) {
                return false
            }

            let confirmationManager = owningTabManager ?? AppDelegate.shared?.tabManagerFor(tabId: id) ?? AppDelegate.shared?.tabManager
            if let confirmationManager, !confirmationManager.beginCloseConfirmationSession() {
                return false
            }

            pendingCloseConfirmTabIds.insert(tab.id)
            let tabId = tab.id
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    confirmationManager?.endCloseConfirmationSession()
                    return
                }
                Task { @MainActor in
                    defer {
                        self.pendingCloseConfirmTabIds.remove(tabId)
                        confirmationManager?.endCloseConfirmationSession()
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
        tabStripCloseButtonByTabId.removeValue(forKey: tabId)
        let remoteTmuxWorkspaceCloseButton = remoteTmuxWorkspaceCloseButtonByTabId.removeValue(forKey: tabId)
        let remoteTmuxKeepWorkspaceOpen = remoteTmuxKeepWorkspaceOpenTabIds.remove(tabId) != nil
        if remoteTmuxKeepWorkspaceOpen, remoteTmuxKeepWorkspaceOpenTabIds.isEmpty { remoteTmuxKeepWorkspaceOpenAfterSessionEnd = false }
        let selectTabId = postCloseSelectTabId.removeValue(forKey: tabId)
        let shouldClearSplitZoom = postCloseClearSplitZoomTabIds.remove(tabId) != nil
        let closedBrowserRestoreSnapshot = pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tabId)
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
            owningTabManager?.flushPendingPanelTitleUpdatesForWorkspaceSnapshot()
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
                kind: surfaceKind(for: panel),
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

        if panels.isEmpty {
            if isDetaching {
                pendingRemoteDisconnectReplacement = nil
                scheduleTerminalGeometryReconcile()
                return
            }

            if remoteTmuxWorkspaceCloseButton != nil {
                pendingRemoteDisconnectReplacement = nil; remoteTmuxKeepWorkspaceOpenAfterSessionEnd = false; isRemoteTmuxMirror = false
                remoteTmuxWindowMirrors.removeAll()
                AppDelegate.shared?.remoteTmuxController.detachMirrorWorkspaceKeptOpenLocally(workspaceId: id)
                let manager = owningTabManager ?? AppDelegate.shared?.tabManagerFor(tabId: id) ?? AppDelegate.shared?.tabManager
                if let manager, manager.tabs.count > 1 { manager.closeWorkspace(self, recordHistory: false); scheduleTerminalGeometryReconcile(); return }
                if let manager, let appDelegate = AppDelegate.shared, appDelegate.mainWindowContexts.count > 1,
                   let windowId = appDelegate.windowId(for: manager) { appDelegate.discardMainWindowWithoutClosedHistory(windowId: windowId); scheduleTerminalGeometryReconcile(); return }
            }
            if remoteTmuxKeepWorkspaceOpen {
                pendingRemoteDisconnectReplacement = nil; remoteTmuxKeepWorkspaceOpenAfterSessionEnd = false; isRemoteTmuxMirror = false
                remoteTmuxWindowMirrors.removeAll()
                AppDelegate.shared?.remoteTmuxController.detachMirrorWorkspaceKeptOpenLocally(workspaceId: id)
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

        pendingRemoteDisconnectReplacement = nil

        if let selectTabId,
           bonsplitController.allPaneIds.contains(pane),
           bonsplitController.tabs(inPane: pane).contains(where: { $0.id == selectTabId }),
           bonsplitController.focusedPaneId == pane {
            bonsplitController.selectTab(selectTabId)
            applyTabSelection(tabId: selectTabId, inPane: pane)
        } else if let focusedPane = bonsplitController.focusedPaneId,
                  let focusedTabId = bonsplitController.selectedTab(inPane: focusedPane)?.id {
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
        // In a remote tmux mirror, split means tmux `split-window`; always veto
        // local splits so the mirror never gains an orphan pane.
        guard isRemoteTmuxMirror else { return true }
        if let tabId = bonsplitController.selectedTab(inPane: pane)?.id,
           let panelId = panelIdFromSurfaceId(tabId) {
            _ = AppDelegate.shared?.remoteTmuxController.handleMirrorTabSplitRequested(
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
        AppDelegate.shared?.remoteTmuxController.handleMirrorWindowsReordered(
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
        AppDelegate.shared?.focusLog.append(
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
        let closedPanelIds = pendingPaneClosePanelIds.removeValue(forKey: paneId.id) ?? []
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
               CloseTabWarningStore(defaults: closeTabWarningDefaults).shouldConfirmClose(
                   requiresConfirmation: panelNeedsConfirmClose(panelId: panelId),
                   source: .shortcut
               ) {
                pendingPaneClosePanelIds.removeValue(forKey: pane.id)
                pendingPaneCloseHistoryEntries.removeValue(forKey: pane.id)
                return false
            }
        }
        let panelIds = tabs.compactMap { panelIdFromSurfaceId($0.id) }
        pendingPaneClosePanelIds[pane.id] = panelIds
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
                    bindSurface(replacementTab.id, toPanelId: replacementPanel.id)

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

        bindSurface(newTabId, toPanelId: newPanel.id)
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
                _ = AppDelegate.shared?.performCloudVMAction(
                    tabManager: owningTabManager,
                    preferredWindow: presentingWindow,
                    debugSource: "surfaceTabBar.cloudVM"
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
            promptRenamePanel(tabId: tab.id)
        case .clearName:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            setPanelCustomTitle(panelId: panelId, title: nil)
        case .copyIdentifiers:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            copyIdentifiersToPasteboard(surfaceId: panelId)
        case .closeToLeft:
            closeTabs(tabIdsToLeft(of: tab.id, inPane: pane))
        case .closeToRight:
            closeTabs(tabIdsToRight(of: tab.id, inPane: pane))
        case .closeOthers:
            closeTabs(tabIdsToCloseOthers(of: tab.id, inPane: pane))
        case .move:
            if let destination = bonsplitTabMoveDestinations(for: tab.id).first {
                _ = moveBonsplitTab(tab.id, toMoveDestination: destination.id)
            }
        case .moveToNewWorkspace:
            _ = AppDelegate.shared?.moveBonsplitTabToNewWorkspace(tabId: tab.id.uuid, focus: true, focusWindow: false)
        case .moveToLeftPane:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            _ = moveSurfaceToAdjacentPane(panelId: panelId, direction: .left)
        case .moveToRightPane:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            _ = moveSurfaceToAdjacentPane(panelId: panelId, direction: .right)
        case .newTerminalToRight:
            createTerminalToRight(of: tab.id, inPane: pane)
        case .newBrowserToRight:
            createBrowserToRight(of: tab.id, inPane: pane)
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

    private func handleForkConversationContextAction(_ action: TabContextAction, for tab: Bonsplit.Tab, inPane pane: PaneID) {
        guard let panelId = panelIdFromSurfaceId(tab.id),
              let snapshot = forkableAgentSnapshot(forPanelId: panelId) else {
            NSSound.beep()
            return
        }
        // Mirror the menu-visibility gate exactly: only fork when the snapshot is
        // probe-free supported. Using the weaker `!= .unsupported` here would let a
        // `.requiresProbe` snapshot through if the action is ever wired up outside
        // the bonsplit menu, leading to a fork that may quietly fail at the shell.
        let isRemote = isRemoteTerminalSurface(panelId)
        guard ContentView.commandPaletteSnapshotForkAvailability(
            snapshot,
            isRemoteTerminal: isRemote
        ) == .supportedWithoutProbe else {
            NSSound.beep()
            return
        }

        let destination = action == .forkConversation
            ? AgentConversationForkDefaultSettings.current()
            : AgentConversationForkDestination(tabContextAction: action)
        guard forkAgentConversation(
            fromPanelId: panelId,
            snapshot: snapshot,
            destination: destination,
            anchorTabId: tab.id,
            paneId: pane
        ) else {
            NSSound.beep()
            return
        }
    }

    private func forkAgentConversation(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        destination: AgentConversationForkDestination,
        anchorTabId: TabID,
        paneId: PaneID
    ) -> Bool {
        if let direction = destination.splitDirection {
            return forkAgentConversation(
                fromPanelId: panelId,
                snapshot: snapshot,
                direction: direction
            ) != nil
        }

        switch destination {
        case .newTab:
            return forkAgentConversationToNewTab(
                fromPanelId: panelId,
                snapshot: snapshot,
                anchorTabId: anchorTabId,
                paneId: paneId
            ) != nil
        case .newWorkspace:
            return forkAgentConversationToNewWorkspace(
                fromPanelId: panelId,
                snapshot: snapshot
            )
        case .right, .left, .top, .bottom:
            return false
        }
    }

    private func forkAgentConversationToNewWorkspace(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot
    ) -> Bool {
        guard let owningTabManager,
              let launch = forkAgentWorkspaceLaunch(
                  fromPanelId: panelId,
                  snapshot: snapshot
              ) else {
            return false
        }

        let forkWorkspace = owningTabManager.addWorkspace(
            workingDirectory: launch.terminalWorkingDirectory,
            initialTerminalCommand: launch.initialTerminalCommand,
            initialTerminalInput: launch.initialTerminalInput,
            initialTerminalEnvironment: launch.initialTerminalEnvironment,
            inheritWorkingDirectory: launch.terminalWorkingDirectory != nil,
            autoWelcomeIfNeeded: false
        )
        if let remoteConfiguration = launch.remoteConfiguration {
            forkWorkspace.configureRemoteConnection(
                remoteConfiguration,
                autoConnect: launch.autoConnectRemoteConfiguration
            )
        }
        if let workingDirectory = launch.workingDirectory,
           launch.terminalWorkingDirectory == nil,
           let forkPanelId = forkWorkspace.focusedPanelId {
            forkWorkspace.updatePanelDirectory(panelId: forkPanelId, directory: workingDirectory)
        }
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didRequestTabMoveToDestination destinationId: String, for tab: Bonsplit.Tab, inPane pane: PaneID) {
        _ = moveBonsplitTab(tab.id, toMoveDestination: destinationId)
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
