import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CmuxFileWatch
import CmuxGit
import CmuxProcess
import CoreVideo
import Combine
import CoreServices
import Darwin
import OSLog


// MARK: - Session Snapshot
extension TabManager {
    func sessionAutosaveFingerprint(
        restorableAgentIndex: RestorableAgentSessionIndex = .empty,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex = .empty
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(selectedTabId)
        hasher.combine(tabs.count)
        let notificationStore = AppDelegate.shared?.notificationStore

        // Workspace groups participate in the session snapshot, so changes
        // that only touch group metadata (rename / collapse / pin a group,
        // or move a workspace between groups without reordering tabs) must
        // bump the fingerprint or the autosave timer skips the write.
        hasher.combine(workspaceGroups.count)
        for group in workspaceGroups {
            hasher.combine(group.id)
            hasher.combine(group.name)
            hasher.combine(group.isCollapsed)
            hasher.combine(group.isPinned)
            hasher.combine(group.anchorWorkspaceId)
            hasher.combine(group.customColor ?? "")
            hasher.combine(group.iconSymbol ?? "")
        }
        for workspace in tabs.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow) {
            hasher.combine(workspace.id)
            hasher.combine(workspace.groupId)
            hasher.combine(workspace.focusedPanelId)
            hasher.combine(workspace.currentDirectory)
            hasher.combine(workspace.customTitle ?? "")
            hasher.combine(workspace.customDescription ?? "")
            hasher.combine(workspace.customColor ?? "")
            hasher.combine(workspace.isPinned)
            hasher.combine(workspace.panels.count)
            hasher.combine(workspace.statusEntries.count)
            hasher.combine(workspace.metadataBlocks.count)
            hasher.combine(workspace.logEntries.count)
            hasher.combine(workspace.panelDirectories.count)
            hasher.combine(workspace.panelTitles.count)
            hasher.combine(workspace.panelPullRequests.count)
            hasher.combine(workspace.panelGitBranches.count)
            hasher.combine(workspace.surfaceListeningPorts.count)
            hasher.combine(notificationStore?.hasManualUnread(forTabId: workspace.id) ?? false)
            hasher.combine(notificationStore?.workspaceIsUnread(forTabId: workspace.id) ?? false)
            Self.hashNotifications(
                notificationStore?.notifications(forTabId: workspace.id, surfaceId: nil) ?? [],
                into: &hasher
            )

            let panelIds = workspace.panels.keys.sorted { $0.uuidString < $1.uuidString }
            hasher.combine(panelIds.count)
            for panelId in panelIds {
                hasher.combine(panelId)
                hasher.combine(workspace.manualUnreadPanelIds.contains(panelId))
                hasher.combine(workspace.restoredUnreadPanelIds.contains(panelId))
                hasher.combine(workspace.restoredUnreadIndicatorContributesToWorkspace(panelId: panelId))
                hasher.combine(
                    notificationStore?.hasVisibleNotificationIndicator(
                        forTabId: workspace.id,
                        surfaceId: panelId
                    ) ?? false
                )
                Self.hashNotifications(
                    notificationStore?.notifications(forTabId: workspace.id, surfaceId: panelId) ?? [],
                    into: &hasher
                )
                Self.hashRestorableAgentSnapshot(
                    restorableAgentIndex.snapshot(
                        workspaceId: workspace.id,
                        panelId: panelId
                    ),
                    into: &hasher
                )
                Self.hashAgentHibernationPanelState(
                    (workspace.panels[panelId] as? TerminalPanel)?.agentHibernationState,
                    into: &hasher
                )
                Self.hashSurfaceResumeBindingSnapshot(
                    workspace.effectiveSurfaceResumeBinding(
                        panelId: panelId,
                        surfaceResumeBindingIndex: surfaceResumeBindingIndex
                    ),
                    into: &hasher
                )
                if let terminalPanel = workspace.terminalPanel(for: panelId) {
                    Self.hashTextBoxDraftSnapshot(
                        terminalPanel.sessionTextBoxDraftSnapshot(),
                        into: &hasher
                    )
                } else {
                    hasher.combine(false)
                }
            }

            if let progress = workspace.progress {
                hasher.combine(Int((progress.value * 1000).rounded()))
                hasher.combine(progress.label)
            } else {
                hasher.combine(-1)
            }

            if let gitBranch = workspace.gitBranch {
                hasher.combine(gitBranch.branch)
                hasher.combine(gitBranch.isDirty)
            } else {
                hasher.combine("")
                hasher.combine(false)
            }
        }

        return hasher.finalize()
    }

    nonisolated static func restorableAgentSnapshotFingerprint(
        _ snapshot: SessionRestorableAgentSnapshot?
    ) -> Int {
        var hasher = Hasher()
        hashRestorableAgentSnapshot(snapshot, into: &hasher)
        return hasher.finalize()
    }

    nonisolated private static func hashRestorableAgentSnapshot(
        _ snapshot: SessionRestorableAgentSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hasher.combine(snapshot.kind.rawValue)
        hasher.combine(snapshot.sessionId)
        hashOptionalString(snapshot.workingDirectory, into: &hasher)
        hashAgentLaunchCommand(snapshot.launchCommand, into: &hasher)
    }

    nonisolated private static func hashAgentLaunchCommand(
        _ launchCommand: AgentLaunchCommandSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let launchCommand else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hashOptionalString(launchCommand.launcher, into: &hasher)
        hashOptionalString(launchCommand.executablePath, into: &hasher)
        hasher.combine(launchCommand.arguments)
        hashOptionalString(launchCommand.workingDirectory, into: &hasher)
        if let environment = launchCommand.environment {
            hasher.combine(true)
            hasher.combine(environment.count)
            for key in environment.keys.sorted() {
                hasher.combine(key)
                hasher.combine(environment[key])
            }
        } else {
            hasher.combine(false)
        }
        hashOptionalDouble(launchCommand.capturedAt, into: &hasher)
        hashOptionalString(launchCommand.source, into: &hasher)
    }

    private static func hashAgentHibernationPanelState(
        _ state: AgentHibernationPanelState?,
        into hasher: inout Hasher
    ) {
        guard let state else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hashRestorableAgentSnapshot(state.agent, into: &hasher)
        hasher.combine(state.hibernatedAt.timeIntervalSince1970)
        hasher.combine(state.lastActivityAt.timeIntervalSince1970)
    }

    nonisolated private static func hashSurfaceResumeBindingSnapshot(
        _ snapshot: SurfaceResumeBindingSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hashOptionalString(snapshot.name, into: &hasher)
        hashOptionalString(snapshot.kind, into: &hasher)
        hasher.combine(snapshot.command)
        hashOptionalString(snapshot.cwd, into: &hasher)
        hashOptionalString(snapshot.checkpointId, into: &hasher)
        hashOptionalString(snapshot.source, into: &hasher)
        hashStringMap(snapshot.environment, into: &hasher)
        hasher.combine(snapshot.allowsAutomaticResume)
        if snapshot.isProcessDetected {
            hasher.combine(false)
        } else {
            hashOptionalDouble(snapshot.updatedAt, into: &hasher)
        }
    }

    nonisolated private static func hashTextBoxDraftSnapshot(
        _ snapshot: SessionTextBoxInputDraftSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hasher.combine(snapshot.isActive)
        hasher.combine(snapshot.parts.count)
        for part in snapshot.parts {
            hasher.combine(part.kind.rawValue)
            hashOptionalString(part.text, into: &hasher)
            hashTextBoxAttachmentSnapshot(part.attachment, into: &hasher)
        }
    }

    nonisolated private static func hashTextBoxAttachmentSnapshot(
        _ snapshot: SessionTextBoxInputAttachmentSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hasher.combine(snapshot.displayName)
        hasher.combine(snapshot.submissionText)
        hasher.combine(snapshot.submissionPath)
        hashOptionalString(snapshot.localPath, into: &hasher)
        hasher.combine(snapshot.cleanupLocalPathWhenDisposed)
    }

    nonisolated private static func hashNotifications(
        _ notifications: [TerminalNotification],
        into hasher: inout Hasher
    ) {
        hasher.combine(notifications.count)
        for notification in notifications.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            hasher.combine(notification.id)
            hasher.combine(notification.title)
            hasher.combine(notification.subtitle)
            hasher.combine(notification.body)
            hasher.combine(notification.createdAt.timeIntervalSince1970)
            hasher.combine(notification.isRead)
            hasher.combine(notification.paneFlash)
            hasher.combine(notification.panelId)
            hasher.combine(notification.clickAction)
        }
    }

    nonisolated private static func hashOptionalString(_ value: String?, into hasher: inout Hasher) {
        if let value {
            hasher.combine(true)
            hasher.combine(value)
        } else {
            hasher.combine(false)
        }
    }

    nonisolated private static func hashOptionalDouble(_ value: Double?, into hasher: inout Hasher) {
        if let value {
            hasher.combine(true)
            hasher.combine(value)
        } else {
            hasher.combine(false)
        }
    }

    nonisolated private static func hashStringMap(_ value: [String: String]?, into hasher: inout Hasher) {
        guard let value, !value.isEmpty else {
            hasher.combine(false)
            return
        }
        hasher.combine(true)
        let keys = value.keys.sorted()
        hasher.combine(keys.count)
        for key in keys {
            hasher.combine(key)
            hasher.combine(value[key] ?? "")
        }
    }

    func sessionSnapshot(
        includeScrollback: Bool,
        restorableAgentIndex: RestorableAgentSessionIndex = .empty,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil
    ) -> SessionTabManagerSnapshot {
        let restorableTabs = tabs
            .filter(\.isRestorableInSessionSnapshot)
            .prefix(SessionPersistencePolicy.maxWorkspacesPerWindow)
        let workspaceSnapshots = restorableTabs
            .map {
                $0.sessionSnapshot(
                    includeScrollback: includeScrollback,
                    restorableAgentIndex: restorableAgentIndex,
                    surfaceResumeBindingIndex: surfaceResumeBindingIndex
                )
            }
        let selectedWorkspaceIndex = selectedTabId.flatMap { selectedTabId in
            restorableTabs.firstIndex(where: { $0.id == selectedTabId })
        }
        let occupiedGroupIds = Set(restorableTabs.compactMap(\.groupId))
        // Build a per-group ordered list of restorable member IDs so we can
        // record the anchor's index (restore-stable across UUID rotation).
        let restorableMembersByGroupId: [UUID: [UUID]] = {
            var map: [UUID: [UUID]] = [:]
            for tab in restorableTabs {
                if let gid = tab.groupId {
                    map[gid, default: []].append(tab.id)
                }
            }
            return map
        }()
        let groupSnapshots: [SessionWorkspaceGroupSnapshot]? = {
            let snapshots = workspaceGroups
                .filter { occupiedGroupIds.contains($0.id) }
                .map { group in
                    let memberIds = restorableMembersByGroupId[group.id] ?? []
                    let anchorIndex = memberIds.firstIndex(of: group.anchorWorkspaceId)
                    return SessionWorkspaceGroupSnapshot(
                        id: group.id,
                        name: group.name,
                        isCollapsed: group.isCollapsed,
                        anchorWorkspaceId: group.anchorWorkspaceId,
                        anchorMemberIndex: anchorIndex,
                        isPinned: group.isPinned,
                        customColor: group.customColor,
                        iconSymbol: group.iconSymbol
                    )
                }
            return snapshots.isEmpty ? nil : snapshots
        }()
        return SessionTabManagerSnapshot(
            selectedWorkspaceIndex: selectedWorkspaceIndex,
            workspaces: workspaceSnapshots,
            workspaceGroups: groupSnapshots
        )
    }

    func sessionSnapshotWorkspaceIds() -> [UUID] {
        Array(
            tabs
                .filter(\.isRestorableInSessionSnapshot)
                .prefix(SessionPersistencePolicy.maxWorkspacesPerWindow)
                .map(\.id)
        )
    }

    private func releaseRestoredAwayWorkspace(_ workspace: Workspace) {
        // Session restore replaces the bootstrap workspace objects with freshly
        // restored ones. Tear the old graph down after the atomic swap so late
        // panel/socket callbacks cannot keep mutating hidden pre-restore state.
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: workspace.id)
        workspace.teardownAllPanels()
        workspace.teardownRemoteConnection()
        workspace.owningTabManager = nil
    }

    @discardableResult
    func restoreSessionSnapshot(
        _ snapshot: SessionTabManagerSnapshot,
        remapClosedPanelHistory: Bool = true
    ) -> [[UUID: UUID]] {
        isRestoringSessionSnapshot = true
        defer { isRestoringSessionSnapshot = false }
        let previousTabs = tabs
        for tab in previousTabs {
            unwireClosedBrowserTracking(for: tab)
        }
        ClosedItemHistoryStore.shared.removePanelRecords(
            forWorkspaceIds: Set(previousTabs.map(\.id))
        )
        let existingProbeKeys = Set(workspaceGitProbeStateByKey.keys)
            .union(workspaceGitProbeTasksByKey.keys)
        for key in existingProbeKeys {
            clearWorkspaceGitProbe(key)
        }
        workspaceGitTrackedDirectoryByKey.removeAll()
        updateWorkspaceGitMetadataFallbackTimer()
        resetWorkspacePullRequestRefreshState()

        // Clear bookkeeping state without touching tabs/selectedTabId yet.
        lastFocusedPanelByTab.removeAll()
        pendingPanelTitleUpdates.removeAll()
        focusHistory.removeAll()
        historyIndex = -1
        focusHistoryRecordingSuppressionDepth = 0
        focusHistorySuppressedSelectionSideEffectGenerations.removeAll()
        focusHistoryRevision &+= 1
        pendingWorkspaceUnfocusTarget = nil
        workspaceCycleCooldownTask?.cancel()
        workspaceCycleCooldownTask = nil
        isWorkspaceCycleHot = false
        selectionSideEffectsGeneration &+= 1
        recentlyClosedBrowsers = RecentlyClosedBrowserStack(capacity: 20)

        // Build the new workspace list locally to avoid intermediate observable
        // emissions (empty tabs, nil selectedTabId) that can leave SwiftUI's
        // mountedWorkspaceIds empty and cause a frozen blank launch state (#399).
        var newTabs: [Workspace] = []
        var restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]] = []
        let workspaceSnapshots = snapshot.workspaces
            .prefix(SessionPersistencePolicy.maxWorkspacesPerWindow)
        var restoredOriginalWorkspaceIds: [UUID?] = []
        for workspaceSnapshot in workspaceSnapshots {
            let ordinal = Self.nextPortOrdinal
            Self.nextPortOrdinal += 1
            let workspace = Workspace(
                title: workspaceSnapshot.processTitle,
                workingDirectory: workspaceSnapshot.currentDirectory,
                portOrdinal: ordinal
            )
            workspace.owningTabManager = self
            let restoredPanelIds = workspace.restoreSessionSnapshot(workspaceSnapshot)
            wireClosedBrowserTracking(for: workspace)
            newTabs.append(workspace)
            restoredPanelIdsByWorkspaceIndex.append(restoredPanelIds)
            restoredOriginalWorkspaceIds.append(workspaceSnapshot.workspaceId)
        }

        if newTabs.isEmpty {
            let ordinal = Self.nextPortOrdinal
            Self.nextPortOrdinal += 1
            let fallback = Workspace(title: "Terminal 1", portOrdinal: ordinal)
            fallback.owningTabManager = self
            wireClosedBrowserTracking(for: fallback)
            newTabs.append(fallback)
        }

        // Determine selection before mutating observed properties.
        let newSelectedId: UUID?
        if let selectedWorkspaceIndex = snapshot.selectedWorkspaceIndex,
           newTabs.indices.contains(selectedWorkspaceIndex) {
            newSelectedId = newTabs[selectedWorkspaceIndex].id
        } else {
            newSelectedId = newTabs.first?.id
        }

        // Single atomic assignment of the observed properties so SwiftUI observers
        // never see an intermediate state with empty tabs or nil selection.
        tabs = newTabs
        let restoredGroups: [WorkspaceGroup] = {
            guard let groupSnapshots = snapshot.workspaceGroups else { return [] }
            let workspaceIdsByGroupId: [UUID: [UUID]] = {
                var map: [UUID: [UUID]] = [:]
                for workspace in newTabs {
                    if let gid = workspace.groupId {
                        map[gid, default: []].append(workspace.id)
                    }
                }
                return map
            }()
            var seen: Set<UUID> = []
            return groupSnapshots.compactMap { groupSnapshot in
                guard let members = workspaceIdsByGroupId[groupSnapshot.id], !members.isEmpty,
                      seen.insert(groupSnapshot.id).inserted else { return nil }
                // Resolve anchor: prefer the restore-stable index (since each
                // restored workspace gets a fresh UUID, the old
                // anchorWorkspaceId rarely matches). Fall back to the in-process
                // UUID hint, then to "first member by tab order" for very old
                // snapshots that pre-date both fields.
                let anchorId: UUID = {
                    if let index = groupSnapshot.anchorMemberIndex,
                       members.indices.contains(index) {
                        return members[index]
                    }
                    if let stored = groupSnapshot.anchorWorkspaceId, members.contains(stored) {
                        return stored
                    }
                    return members[0]
                }()
                return WorkspaceGroup(
                    id: groupSnapshot.id,
                    name: groupSnapshot.name,
                    isCollapsed: groupSnapshot.isCollapsed,
                    isPinned: groupSnapshot.isPinned ?? false,
                    anchorWorkspaceId: anchorId,
                    customColor: groupSnapshot.customColor,
                    iconSymbol: groupSnapshot.iconSymbol
                )
            }
        }()
        // Clear any group references on restored workspaces that no longer correspond
        // to a known group (older snapshots, manual edits, etc.).
        let knownGroupIds = Set(restoredGroups.map(\.id))
        for workspace in newTabs where workspace.groupId.map({ !knownGroupIds.contains($0) }) ?? false {
            workspace.groupId = nil
        }
        workspaceGroups = restoredGroups
        selectedTabId = newSelectedId
        let existingIds = Set(newTabs.map(\.id))
        pruneBackgroundWorkspaceLoads(existingIds: existingIds)
        sidebarSelectedWorkspaceIds.formIntersection(existingIds)
        for workspace in previousTabs {
            releaseRestoredAwayWorkspace(workspace)
        }
        for workspace in newTabs {
            let terminalPanels = workspace.panels.values.compactMap { $0 as? TerminalPanel }
            for terminalPanel in terminalPanels {
                scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: workspace.id,
                    panelId: terminalPanel.id
                )
            }
        }
        if remapClosedPanelHistory {
            remapClosedPanelHistoryAfterSessionRestore(
                originalWorkspaceIds: restoredOriginalWorkspaceIds,
                restoredPanelIdsByWorkspaceIndex: restoredPanelIdsByWorkspaceIndex
            )
        }

        if let selectedTabId {
            NotificationCenter.default.post(
                name: .ghosttyDidFocusTab,
                object: nil,
                userInfo: [GhosttyNotificationKey.tabId: selectedTabId]
            )
        }
        return restoredPanelIdsByWorkspaceIndex
    }

    func remapClosedPanelHistoryAfterSessionRestore(
        originalWorkspaceIds: [UUID?],
        restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]]
    ) {
        let count = min(originalWorkspaceIds.count, tabs.count)
        guard count > 0 else { return }
        var didRequestHistoryRemap = false
        for index in 0..<count {
            guard let originalWorkspaceId = originalWorkspaceIds[index],
                  originalWorkspaceId != tabs[index].id else {
                continue
            }
            didRequestHistoryRemap = true
            let panelIdMap = restoredPanelIdsByWorkspaceIndex.indices.contains(index)
                ? restoredPanelIdsByWorkspaceIndex[index]
                : [:]
            ClosedItemHistoryStore.shared.remapPanelWorkspaceIds(
                from: originalWorkspaceId,
                to: tabs[index].id,
                panelIdMap: panelIdMap
            )
        }
        if didRequestHistoryRemap {
            ClosedItemHistoryStore.shared.flushPendingSaves()
        }
    }

    func remapClosedPanelHistoryAfterWindowRestore(
        originalWorkspaceIds: [UUID],
        restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]]
    ) {
        guard !originalWorkspaceIds.isEmpty else { return }
        let count = min(originalWorkspaceIds.count, tabs.count)
        guard count > 0 else { return }
        var didRequestHistoryRemap = false
        for index in 0..<count {
            didRequestHistoryRemap = true
            let panelIdMap = restoredPanelIdsByWorkspaceIndex.indices.contains(index)
                ? restoredPanelIdsByWorkspaceIndex[index]
                : [:]
            ClosedItemHistoryStore.shared.remapPanelWorkspaceIds(
                from: originalWorkspaceIds[index],
                to: tabs[index].id,
                panelIdMap: panelIdMap
            )
        }
        if didRequestHistoryRemap {
            ClosedItemHistoryStore.shared.flushPendingSaves()
        }
    }
}

