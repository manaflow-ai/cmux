import Foundation
import Bonsplit
import CMUXAgentLaunch
import CmuxCore
import CmuxWorkspaces

extension Workspace {
    func sessionSnapshot(
        includeScrollback: Bool,
        restorableAgentIndex: RestorableAgentSessionIndex? = nil,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil,
        downgradeStoredProcessDetectedResumeBindingsWhenDetectionUnavailable: Bool = false,
        currentAgentProcessIdentity: (Int) -> AgentPIDProcessIdentity? = {
            guard $0 > 0, $0 <= Int(Int32.max) else { return nil }
            return AgentPIDProcessIdentity(pid: pid_t($0))
        },
        agentProcessPresence: (Int) -> PIDPresence = {
            guard $0 > 0, $0 <= Int(Int32.max) else { return .absent }
            return PIDPresence.current(pid: pid_t($0))
        }
    ) -> SessionWorkspaceSnapshot {
        let layoutCodec = SessionSplitContainerLayoutCodec(controller: bonsplitController)
        let rawLayout = layoutCodec.snapshot(panelIdForTabId: { [self] in surfaceIdToPanelId[$0] })
        if let surfaceResumeBindingIndex {
            reconcileSurfaceResumeBindings(
                using: surfaceResumeBindingIndex,
                restorableAgentIndex: restorableAgentIndex
            )
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
        let terminalFontSizeSnapshotProjection =
            terminalFontSizeChangeArbiter?.snapshotProjection(
                for: self,
                panelIds: Set(allPanelIds)
            )
        let panelSnapshots = allPanelIds
            .prefix(SessionPersistencePolicy.maxPanelsPerWorkspace)
            .compactMap { panelId in
                sessionPanelSnapshot(
                    panelId: panelId,
                    includeScrollback: includeScrollback,
                    restorableAgentObservation: restorableAgentIndex?.entryForStablePanel(
                        workspaceId: id,
                        panelId: panelId,
                        processIdentityProvider: currentAgentProcessIdentity,
                        processPresenceProvider: agentProcessPresence,
                        // Snapshot projection already consumes one index result;
                        // avoid synchronous sysctl/kill probes on the main actor
                        // while autosaving or closing a workspace.
                        revalidateProcessEvidence: false
                    ),
                    resumeBinding: effectiveSurfaceResumeBinding(
                        panelId: panelId,
                        surfaceResumeBindingIndex: surfaceResumeBindingIndex,
                        downgradeStoredProcessDetectedResumeBindingWhenDetectionUnavailable:
                            downgradeStoredProcessDetectedResumeBindingsWhenDetectionUnavailable
                    ),
                    terminalFontSizeSnapshotProjection:
                        terminalFontSizeSnapshotProjection,
                    currentAgentProcessIdentity: currentAgentProcessIdentity,
                    agentProcessPresence: agentProcessPresence
                )
            }
        let persistedPanelIds = Set(panelSnapshots.map(\.id))
        let layout = layoutCodec.pruned(rawLayout, keeping: persistedPanelIds) ?? .pane(
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
        let logEntriesForSnapshot = isDefaultFreestyleSSHDRemoteWorkspace
            ? logEntries.filter { !Self.isProxyOnlyRemoteLogEntry($0) }
            : logEntries
        let logSnapshots = logEntriesForSnapshot.map { entry in
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
        var snapshot = SessionWorkspaceSnapshot(
            workspaceId: id,
            stableId: stableId,
            taskCreateOperationID: taskCreateOperationID,
            processTitle: processTitle,
            customTitle: customTitle,
            customTitleSource: effectiveCustomTitleSource == .remote ? .user : effectiveCustomTitleSource,
            customTitleWasRemote: effectiveCustomTitleSource == .remote ? true : nil,
            customDescription: customDescription,
            customColor: customColor,
            isPinned: isPinned,
            isMuted: isMuted,
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
            cloudVM: cloudVMBinding.map { SessionCloudVMBindingSnapshot(vmID: $0.vmID, isBase: $0.isBase, remoteWorkspaceID: $0.remoteWorkspaceID) },
            surfaceProjections: surfaceProjectionRecordsForSession,
            environment: workspaceEnvironment.isEmpty ? nil : workspaceEnvironment
        )
        snapshot.captureTodoState(from: self)
        snapshot.dock = _dockSplit?.sessionSnapshot(
            includeScrollback: includeScrollback,
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: surfaceResumeBindingIndex,
            downgradeStoredProcessDetectedResumeBindingsWhenDetectionUnavailable:
                downgradeStoredProcessDetectedResumeBindingsWhenDetectionUnavailable
        )
        return snapshot
    }

    /// Rebuilds workspace state while keeping structured terminal restores
    /// behind the topology boundary selected by `startupRestoreCommitOwner`.
    func restoreSessionLayout(_ layout: SessionWorkspaceLayoutSnapshot) -> [SessionPaneRestoreEntry] {
        guard let rootPaneId = bonsplitController.allPaneIds.first else {
            return []
        }

        var leaves: [SessionPaneRestoreEntry] = []
        restoreSessionLayoutNode(layout, inPane: rootPaneId, leaves: &leaves)
        return leaves
    }

    func restoreSessionLayoutNode(
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

    func restoreAgentIndex(
        for panels: [SessionPanelSnapshot]
    ) -> RestorableAgentSessionIndex? {
        // Load at most once for this restore pass; every panel reuses the same snapshot.
        guard AgentSessionAutoResumeSettings.isEnabled(
            defaults: agentSessionAutoResumeDefaults
        ), panels.contains(where: { panel in
            panel.terminal?.agent != nil || panel.terminal?.resumeBinding?.isAgentHookBinding == true
        }) else {
            return nil
        }
        // Ownership-sensitive restore decisions use an injected authoritative
        // index, or request a fresh off-main scan and defer launch otherwise.
        return restorableAgentIndexProvider()
    }

    func restorePane(
        _ paneId: PaneID,
        snapshot: SessionPaneLayoutSnapshot,
        panelSnapshotsById: [UUID: SessionPanelSnapshot],
        snapshotWorkspaceId: UUID?,
        shouldRestoreSingleDefaultCloudTerminal: Bool,
        restorableAgentIndex: RestorableAgentSessionIndex?,
        oldToNewPanelIds: inout [UUID: UUID]
    ) {
        let existingPanelIds = bonsplitController
            .tabs(inPane: paneId)
            .compactMap { panelIdFromSurfaceId($0.id) }
        let desiredOldPanelIds = snapshot.panelIds.filter { panelSnapshotsById[$0] != nil }
        _ = bonsplitController.setFullWidthTabMode(false, inPane: paneId)

        var createdPanelIds: [UUID] = []
        for oldPanelId in desiredOldPanelIds {
            guard let panelSnapshot = panelSnapshotsById[oldPanelId] else { continue }
            guard let createdPanelId = createPanel(
                from: panelSnapshot,
                inPane: paneId,
                snapshotWorkspaceId: snapshotWorkspaceId,
                shouldRestoreSingleDefaultCloudTerminal: shouldRestoreSingleDefaultCloudTerminal,
                restorableAgentIndex: restorableAgentIndex
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

        if snapshot.isFullWidthTabMode == true {
            _ = bonsplitController.setFullWidthTabMode(true, inPane: paneId)
        }
    }

    func reconcileSurfaceResumeBindings(
        using surfaceResumeBindingIndex: SurfaceResumeBindingIndex,
        restorableAgentIndex: RestorableAgentSessionIndex? = nil
    ) {
        for panelId in panels.keys {
            let storedBinding = surfaceResumeBindingsByPanelId[panelId]
            let detectedBinding = surfaceResumeBindingIndex.binding(workspaceId: id, panelId: panelId)
            if surfaceResumeBindingIndex.hasAmbiguousPanel(panelId), detectedBinding == nil {
                // A missing panel-only winner is uncertainty, not proof that a
                // process-backed binding exited; preserve the existing binding.
                continue
            }

            if let detectedBinding, detectedBinding.isPlainSSHProcessDetectedBinding {
                // A fresh process observation is authoritative evidence that
                // the SSH child is still alive.  It also closes the restore
                // observation gap so later misses can be interpreted as an
                // actual exit rather than startup churn.
                observedPlainSSHPanelIds.insert(panelId)
                pendingPlainSSHRestorePanelIds.remove(panelId)
                plainSSHDetectionMissesByPanelId[panelId] = 0
            }

            guard let storedBinding else {
                if let detectedBinding, detectedBinding.isProcessDetected {
                    guard surfaceResumeBindingMutationAllowed(
                        detectedBinding,
                        panelId: panelId
                    ) else {
                        continue
                    }
                    surfaceResumeBindingsByPanelId[panelId] = detectedBinding
                }
                continue
            }
            guard let detectedBinding else {
                if storedBinding.isPlainSSHProcessDetectedBinding {
                    if pendingPlainSSHRestorePanelIds.contains(panelId) {
                        // The restored PTY may not have exec'd `ssh` yet. Keep
                        // the binding for a bounded restore observation gap;
                        // the shell activity transition below retires it if
                        // SSH never starts.
                        let restoreMisses = (plainSSHDetectionMissesByPanelId[panelId] ?? 0) + 1
                        plainSSHDetectionMissesByPanelId[panelId] = restoreMisses
                        if restoreMisses >= Self.plainSSHRestoreObservationMissLimit {
                            guard surfaceResumeBindingRemovalAllowed(panelId: panelId) else {
                                continue
                            }
                            surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
                            pendingPlainSSHRestorePanelIds.remove(panelId)
                            plainSSHDetectionMissesByPanelId.removeValue(forKey: panelId)
                        }
                        continue
                    }
                    let misses = (plainSSHDetectionMissesByPanelId[panelId] ?? 0) + 1
                    plainSSHDetectionMissesByPanelId[panelId] = misses
                    if misses >= 2 {
                        guard surfaceResumeBindingRemovalAllowed(panelId: panelId) else {
                            continue
                        }
                        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
                        observedPlainSSHPanelIds.remove(panelId)
                        plainSSHDetectionMissesByPanelId.removeValue(forKey: panelId)
                    }
                    continue
                }
                if storedBinding.isProcessDetected {
                    guard surfaceResumeBindingRemovalAllowed(panelId: panelId) else {
                        continue
                    }
                    surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
                } else if isStaleAgentHookBinding(
                    storedBinding,
                    panelId: panelId,
                    restorableAgentIndex: restorableAgentIndex
                ) {
                    // Preserve explicit restore for the exited session, but
                    // prevent the stale binding from replaying automatically
                    // on the next relaunch (#8446).
                    retireAgentHookResumeBinding(panelId: panelId)
                }
                continue
            }
            if storedBinding.shouldYieldToDetectedSurfaceResumeBinding(detectedBinding) {
                guard surfaceResumeBindingMutationAllowed(
                    detectedBinding,
                    panelId: panelId
                ) else {
                    continue
                }
                invalidateRestoredAgentLifecycleIfBindingIsReplaced(
                    by: detectedBinding,
                    panelId: panelId
                )
                surfaceResumeBindingsByPanelId[panelId] = detectedBinding
            } else if storedBinding.isProcessDetected {
                guard surfaceResumeBindingRemovalAllowed(panelId: panelId) else {
                    continue
                }
                surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
                observedPlainSSHPanelIds.remove(panelId)
                pendingPlainSSHRestorePanelIds.remove(panelId)
                plainSSHDetectionMissesByPanelId.removeValue(forKey: panelId)
            }
        }
    }

    func effectiveSurfaceResumeBinding(
        panelId: UUID,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex?,
        downgradeStoredProcessDetectedResumeBindingWhenDetectionUnavailable: Bool = false
    ) -> SurfaceResumeBindingSnapshot? {
        let storedBinding = surfaceResumeBindingsByPanelId[panelId]
        guard let surfaceResumeBindingIndex else {
            guard var storedBinding,
                  storedBinding.isProcessDetected,
                  downgradeStoredProcessDetectedResumeBindingWhenDetectionUnavailable else {
                return storedBinding
            }
            // A windowless recovery freeze cannot synchronously verify process
            // detection after it releases this workspace graph. Preserve the
            // command for manual recovery without trusting it to auto-run.
            storedBinding.autoResume = false
            storedBinding.approvalPolicy = .manual
            storedBinding.approvalRecordId = nil
            surfaceResumeBindingsByPanelId[panelId] = storedBinding
            return storedBinding
        }

        let detectedBinding = surfaceResumeBindingIndex.binding(workspaceId: id, panelId: panelId)
        if surfaceResumeBindingIndex.hasAmbiguousPanel(panelId), detectedBinding == nil {
            // Keep an uncertain binding available for explicit manual resume,
            // but never carry process-detected auto-launch through ambiguity.
            return storedBinding?.disablingAutomaticResume()
        }
        guard let storedBinding else { return detectedBinding }
        guard let detectedBinding else {
            if storedBinding.isPlainSSHProcessDetectedBinding {
                let misses = plainSSHDetectionMissesByPanelId[panelId] ?? 0
                if pendingPlainSSHRestorePanelIds.contains(panelId) || misses < 2 {
                    return storedBinding
                }
                return nil
            }
            return storedBinding.isProcessDetected ? nil : storedBinding
        }
        if storedBinding.shouldYieldToDetectedSurfaceResumeBinding(detectedBinding) { return detectedBinding }
        if storedBinding.isProcessDetected { return nil }
        return storedBinding
    }

}
