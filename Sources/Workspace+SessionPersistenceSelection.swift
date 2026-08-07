import CmuxTerminal
import Foundation

extension Workspace {
    /// Hashes every live input that can change crash-diagnostic pruning without
    /// serializing full panel payloads for windows outside the persistence cap.
    func combineSessionPersistenceSelectionMetadata(
        into hasher: inout Hasher,
        restorableAgentIndex: RestorableAgentSessionIndex,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex
    ) {
        let notificationStore = AppDelegate.shared?.notificationStore
        hasher.combine(id)
        hasher.combine(currentDirectory)
        hasher.combine(customTitle)
        hasher.combine(customDescription)
        hasher.combine(customColor)
        hasher.combine(isPinned)
        hasher.combine(groupId)
        hasher.combine(remoteConfiguration != nil)
        hasher.combine(notificationStore?.hasManualUnread(forTabId: id) ?? false)
        hasher.combine(notificationStore?.workspaceIsUnread(forTabId: id) ?? false)
        hasher.combine(
            notificationStore?.notifications(forTabId: id, surfaceId: nil).isEmpty == false
        )
        hasher.combine(!canvasModel.persistablePanes.isEmpty)
        hasher.combine(!workspaceEnvironment.isEmpty)
        hasher.combine(!statusEntries.isEmpty)
        hasher.combine(!logEntries.isEmpty)
        hasher.combine(progress != nil)
        hasher.combine(gitBranch != nil)

        let panelIds = sessionPersistenceSelectionPanelIds()
        hasher.combine(panelIds.count)
        for panelId in panelIds {
            guard let panel = panels[panelId] else { continue }
            hasher.combine(panelId)
            hasher.combine(panel.panelType == .terminal)
            hasher.combine(panelDirectories[panelId])
            hasher.combine(panelCustomTitles[panelId])
            hasher.combine(pinnedPanelIds.contains(panelId))
            hasher.combine(manualUnreadPanelIds.contains(panelId))
            hasher.combine(restoredUnreadPanelIds.contains(panelId))
            hasher.combine(restoredUnreadIndicatorContributesToWorkspace(panelId: panelId))
            hasher.combine(panelGitBranches[panelId] != nil)
            hasher.combine(surfaceListeningPorts[panelId]?.isEmpty == false)
            hasher.combine(
                notificationStore?.hasVisibleNotificationIndicator(
                    forTabId: id,
                    surfaceId: panelId
                ) ?? false
            )
            hasher.combine(
                notificationStore?.notifications(forTabId: id, surfaceId: panelId).isEmpty == false
            )

            guard let terminal = panel as? TerminalPanel else { continue }
            hasher.combine(terminal.requestedWorkingDirectory)
            hasher.combine(terminal.surface.sessionFontSizeOverrideBasePoints())
            hasher.combine(restoredTerminalScrollbackByPanelId[panelId])
            hasher.combine(terminal.sessionTextBoxDraftSnapshot() != nil)
            hasher.combine(
                TabManager.restorableAgentSnapshotFingerprint(
                    restorableAgentIndex.snapshot(workspaceId: id, panelId: panelId)
                )
            )
            hasher.combine(
                restorableAgentIndex.entry(
                    workspaceId: id,
                    panelId: panelId
                )?.processLiveness
            )
            hasher.combine(
                TabManager.restorableAgentSnapshotFingerprint(
                    restoredAgentSnapshotsByPanelId[panelId]
                )
            )
            hasher.combine(
                TabManager.restorableAgentSnapshotFingerprint(
                    terminal.agentHibernationState?.agent
                )
            )
            hasher.combine(
                restoredAgentResumeStatesByPanelId[panelId] == .completedAgentExit
            )
            hasher.combine(
                invalidatedRestoredAgentFingerprintsByPanelId[panelId]
            )
            combineSessionPersistenceSelectionBinding(
                effectiveSurfaceResumeBinding(
                    panelId: panelId,
                    surfaceResumeBindingIndex: surfaceResumeBindingIndex
                ),
                into: &hasher
            )
            hasher.combine(terminal.surface.debugTmuxStartCommand())
            hasher.combine(activeRemoteTerminalSurfaceIds.contains(panelId))
            hasher.combine(remotePTYSessionIDsByPanelId[panelId])
        }
    }

    private func sessionPersistenceSelectionPanelIds() -> [UUID] {
        var seen: Set<UUID> = []
        var result: [UUID] = []
        for panelId in sidebarOrderedPanelIds() where seen.insert(panelId).inserted {
            result.append(panelId)
        }
        for panelId in panels.keys.sorted(by: { $0.uuidString < $1.uuidString })
        where seen.insert(panelId).inserted {
            result.append(panelId)
        }
        return Array(result.prefix(SessionPersistencePolicy.maxPanelsPerWorkspace))
    }

    private func combineSessionPersistenceSelectionBinding(
        _ binding: SurfaceResumeBindingSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let binding else {
            hasher.combine(false)
            return
        }
        hasher.combine(true)
        hasher.combine(binding.kind)
        hasher.combine(binding.checkpointId)
        hasher.combine(binding.source)
        hasher.combine(binding.command)
        hasher.combine(binding.cwd)
        hasher.combine(binding.launchFlavor)
    }
}
