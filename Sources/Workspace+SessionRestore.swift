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


// MARK: - Session restore
extension Workspace {
    func restoreSessionLayout(_ layout: SessionWorkspaceLayoutSnapshot) -> [SessionPaneRestoreEntry] {
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

    func restorePane(
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

    func createPanel(
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
            let effectiveResumeBindingForStartup = Self.approvedSurfaceResumeBinding(
                resumeBindingForStartup,
                autoResumeAgentSessions: shouldAutoResumeAgent,
                promptForApproval: true
            )
            let remoteStartupCommand = remoteTerminalStartupCommand()
            let restoredBindingLaunch: SurfaceResumeStartupLaunch? = if remoteStartupCommand != nil {
                effectiveResumeBindingForStartup?
                    .startupInputWithLauncherScript(allowLauncherScript: false)
                    .map(SurfaceResumeStartupLaunch.input)
            } else {
                effectiveResumeBindingForStartup.flatMap {
                    Self.surfaceResumeStartupLaunch(
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
                ? Self.restorableTmuxStartCommand(snapshot.terminal?.tmuxStartCommand)
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
            let shouldReplayScrollback = Self.shouldReplaySessionScrollback(
                restorableAgent: restorableAgent,
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
            let replayEnvironment = SessionScrollbackReplayStore.replayEnvironment(for: restoredScrollback)
            guard let terminalPanel = newTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: localWorkingDirectory,
                initialCommand: restoredStartupCommand,
                tmuxStartCommand: restoredTmuxStartCommand,
                initialInput: restoredStartupInput,
                startupEnvironment: replayEnvironment,
                remotePTYSessionID: restoredRemotePTYSessionID,
                suppressWorkspaceRemoteStartupCommand: suppressWorkspaceRemoteStartupCommand
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
               Self.unmountedVolumeRoot(for: guardedWorkingDirectory) != nil {
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

        setPanelCustomTitle(panelId: panelId, title: snapshot.customTitle)
        setPanelPinned(panelId: panelId, pinned: snapshot.isPinned)

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

    func restoreWorkspaceManualUnread(_ isManuallyUnread: Bool) {
        guard let notificationStore = AppDelegate.shared?.notificationStore else { return }
        if isManuallyUnread {
            notificationStore.markUnread(forTabId: id)
        } else {
            notificationStore.clearManualUnread(forTabId: id)
        }
        syncUnreadBadgeStateForAllPanels()
    }

    func notificationSnapshots(surfaceId: UUID?) -> [SessionNotificationSnapshot] {
        AppDelegate.shared?.notificationStore?
            .notifications(forTabId: id, surfaceId: surfaceId)
            .map(SessionNotificationSnapshot.init(notification:)) ?? []
    }

    func restoredSessionNotifications(
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

    func applySessionDividerPositions(
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
