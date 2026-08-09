import Bonsplit
import CmuxTerminal
import CmuxTerminalCore
import CmuxWorkspaces
import Foundation

extension DockSplitStore {
    @discardableResult
    func restoreSessionSnapshot(
        _ snapshot: SessionSplitContainerSnapshot,
        excludingStableIdentities: Set<UUID> = [],
        sourceWorkspaceResolver: (UUID) -> Workspace? = { _ in nil }
    ) -> [UUID: UUID] {
        cancelConfigurationTasks()
        removeAllPanels()
        hasLoadedConfiguration = true
        hasAppliedConfigurationSeed = true

        let layoutCodec = SessionSplitContainerLayoutCodec(controller: bonsplitController)
        let scaffold = withProgrammaticDockSplit { layoutCodec.restoreScaffold(snapshot.layout) }
        let panelSnapshotsById = Dictionary(uniqueKeysWithValues: snapshot.panels.map { ($0.id, $0) })
        var oldToNewPanelIds: [UUID: UUID] = [:]
        var restoredPanelIds: Set<UUID> = []

        for leaf in scaffold.leaves {
            _ = bonsplitController.setFullWidthTabMode(false, inPane: leaf.paneId)
            let desiredPanelIds = leaf.snapshot.panelIds.filter {
                panelSnapshotsById[$0] != nil && !restoredPanelIds.contains($0)
            }
            var createdPanelIds: [UUID] = []
            for oldPanelId in desiredPanelIds {
                guard let panelSnapshot = panelSnapshotsById[oldPanelId],
                      let newPanelId = createSessionRestoredPanel(
                          from: panelSnapshot,
                          inPane: leaf.paneId,
                          excludingStableIdentities: excludingStableIdentities,
                          sourceWorkspaceId: snapshot.sourceWorkspaceIdsByPanelId?[oldPanelId],
                          sourceSnapshotWorkspaceId:
                            snapshot.sourceWorkspaceIdsByPanelId?[oldPanelId],
                          sourceWorkspaceResolver: sourceWorkspaceResolver
                      ) else {
                    continue
                }
                oldToNewPanelIds[oldPanelId] = newPanelId
                restoredPanelIds.insert(oldPanelId)
                createdPanelIds.append(newPanelId)
            }
            if let selectedOldPanelId = leaf.snapshot.selectedPanelId,
               let selectedPanelId = oldToNewPanelIds[selectedOldPanelId],
               let tabId = surfaceId(forPanelId: selectedPanelId) {
                bonsplitController.focusPane(leaf.paneId)
                bonsplitController.selectTab(tabId)
            } else if let selectedPanelId = createdPanelIds.first,
                      let tabId = surfaceId(forPanelId: selectedPanelId) {
                bonsplitController.focusPane(leaf.paneId)
                bonsplitController.selectTab(tabId)
            }
            if leaf.snapshot.isFullWidthTabMode == true, !createdPanelIds.isEmpty {
                _ = bonsplitController.setFullWidthTabMode(true, inPane: leaf.paneId)
            }
        }

        forceCloseDockTabIds.formUnion(scaffold.placeholderTabIds)
        for tabId in scaffold.placeholderTabIds {
            _ = bonsplitController.closeTab(tabId)
        }
        forceCloseDockTabIds.subtract(scaffold.placeholderTabIds)
        reconcilePanels()

        layoutCodec.applyDividerPositions(
            snapshotNode: snapshot.layout,
            liveNode: bonsplitController.treeSnapshot()
        )
        if let focusedOldPanelId = snapshot.focusedPanelId,
           let focusedPanelId = oldToNewPanelIds[focusedOldPanelId] {
            focusDockController(panelId: focusedPanelId)
        }
        applyVisibilityToAllPanels()
        scheduleDockPortalReconcile(reason: "dock.sessionRestore")
        return oldToNewPanelIds
    }

    /// Recreates one panel inside an existing Dock pane for Dock-local
    /// closed-item history. Unlike a full session restore, this preserves the
    /// rest of the live Dock tree.
    @discardableResult
    func restoreClosedPanelSessionSnapshot(
        _ snapshot: SessionPanelSnapshot,
        inPane paneId: PaneID,
        sourceWorkspaceId: UUID?,
        sourceSnapshotWorkspaceId: UUID?,
        sourceWorkspaceResolver: (UUID) -> Workspace?
    ) -> UUID? {
        createSessionRestoredPanel(
            from: snapshot,
            inPane: paneId,
            excludingStableIdentities: [],
            sourceWorkspaceId: sourceWorkspaceId,
            sourceSnapshotWorkspaceId: sourceSnapshotWorkspaceId,
            sourceWorkspaceResolver: sourceWorkspaceResolver
        )
    }

    private func createSessionRestoredPanel(
        from snapshot: SessionPanelSnapshot,
        inPane paneId: PaneID,
        excludingStableIdentities: Set<UUID>,
        sourceWorkspaceId: UUID?,
        sourceSnapshotWorkspaceId: UUID?,
        sourceWorkspaceResolver: (UUID) -> Workspace?
    ) -> UUID? {
        if let sourceWorkspaceId,
           let sourceWorkspace = sourceWorkspaceResolver(sourceWorkspaceId),
           let detached = sourceWorkspace.detachedSurfaceForDockSessionRestore(
               snapshot,
               snapshotWorkspaceId:
                sourceSnapshotWorkspaceId ?? sourceWorkspaceId,
               excludingStableIdentities: excludingStableIdentities
           ) {
            let restoredPanelId = attachDetachedSurface(detached, inPane: paneId, focus: false)
            if restoredPanelId == nil {
                AgentHibernationController.shared.discardTrackingStateForClosedPanel(
                    workspaceId: detached.sourceWorkspaceId,
                    panelId: detached.panelId
                )
                detached.panel.close()
            }
            return restoredPanelId
        }
        if sourceWorkspaceId != nil,
           snapshot.terminal?.isRemoteTerminal == true {
            return nil
        }
        switch snapshot.type {
        case .terminal:
            return restoreSessionTerminal(
                from: snapshot,
                inPane: paneId,
                excludingStableIdentities: excludingStableIdentities
            )
        case .browser:
            return restoreSessionBrowser(
                from: snapshot,
                inPane: paneId,
                excludingStableIdentities: excludingStableIdentities
            )
        default:
            return nil
        }
    }

    private func restoreSessionTerminal(
        from snapshot: SessionPanelSnapshot,
        inPane paneId: PaneID,
        excludingStableIdentities: Set<UUID>
    ) -> UUID? {
        guard let terminalSnapshot = snapshot.terminal else { return nil }
        let policy = Workspace.makeSessionRestorePolicyService()
        let restorableAgent = Workspace.restorableAgentForSessionRestore(
            terminalSnapshot.agent,
            resumeBinding: terminalSnapshot.resumeBinding
        )
        let hibernation = restorableAgent != nil ? terminalSnapshot.hibernation : nil
        let resumeBinding = Workspace.resumeBindingForSessionRestore(
            terminalSnapshot.resumeBinding,
            restorableAgent: restorableAgent
        )
        let managedResumeBinding = (
            terminalSnapshot.managedAgentResumeBinding.flatMap {
                $0.hasCompleteManagedSessionIdentity ? $0 : nil
            }
                ?? terminalSnapshot.resumeBinding.flatMap {
                    $0.hasCompleteManagedSessionIdentity ? $0 : nil
                }
        ).flatMap { candidate -> SurfaceResumeBindingSnapshot? in
            if restorableAgent != nil,
               Workspace.restorableAgentForSessionRestore(
                   restorableAgent,
                   resumeBinding: candidate
               ) == nil {
                return nil
            }
            return Workspace.resumeBindingForSessionRestore(
                candidate,
                restorableAgent: restorableAgent
            )
        }
        let agentWasRunning = terminalSnapshot.wasAgentRunning ?? true
        let shouldAutoResumeAgent = AgentSessionAutoResumeSettings.isEnabled(
            defaults: agentSessionAutoResumeDefaults
        ) && agentWasRunning
        let resumeBindingForStartup = hibernation != nil ||
            (resumeBinding?.isProcessDetected == true && resumeBinding?.autoResume != true)
            ? nil
            : resumeBinding
        let approvedResumeBinding = policy.approvedSurfaceResumeBinding(
            resumeBindingForStartup,
            autoResumeAgentSessions: shouldAutoResumeAgent,
            promptForApproval: true,
            approvalStoreURL: SurfaceResumeApprovalStore.defaultURL()
        )
        let savedWorkingDirectory = resumeBinding?.cwd
            ?? terminalSnapshot.workingDirectory
            ?? restorableAgent?.workingDirectory
            ?? snapshot.directory
        let workingDirectory = savedWorkingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        let unresolvedBindingLaunch = approvedResumeBinding.flatMap {
            policy.surfaceResumeStartupLaunch(
                forApprovedBinding: $0
            )
        }
        let resumeSessionWorkingDirectory: String? = {
            if unresolvedBindingLaunch != nil {
                return approvedResumeBinding?.cwd ?? workingDirectory
            }
            guard let restorableAgent else { return savedWorkingDirectory }
            if restorableAgent.registration?.cwd == .ignore {
                return nil
            }
            return restorableAgent.workingDirectory
                ?? restorableAgent.launchCommand?.workingDirectory
                ?? workingDirectory
        }()
        let bindingLaunch = unresolvedBindingLaunch
        let tmuxStartCommand = restorableAgent == nil && bindingLaunch == nil
            ? policy.restorableTmuxStartCommand(terminalSnapshot.tmuxStartCommand)
            : nil
        let tmuxLauncher = tmuxStartCommand.flatMap {
            OneShotTerminalLauncherStore().writeStartupCommand(
                command: $0,
                workingDirectory: workingDirectory
            )
        }
        let restoredTmuxStartCommand = tmuxLauncher == nil ? nil : tmuxStartCommand
        let agentSessionAlreadyActive = sessionAgentAlreadyActive(
            restorableAgent: restorableAgent,
            snapshotPanelId: snapshot.id,
            shouldAutoResume: shouldAutoResumeAgent && hibernation == nil && bindingLaunch == nil
        )
        let agentLaunch = shouldAutoResumeAgent && hibernation == nil && bindingLaunch == nil
            && !agentSessionAlreadyActive
            ? restorableAgent?.resumeStartupInput(
                restoringWorkingDirectory: resumeSessionWorkingDirectory
            ).map(WorkspaceSurfaceResumeStartupLaunch.input)
            : nil
        let initialCommand = tmuxLauncher
        let initialInput = bindingLaunch?.initialInput ?? agentLaunch?.initialInput
        let startupHandlesWorkingDirectory =
            tmuxLauncher != nil || agentLaunch != nil || bindingLaunch != nil
        let hostShellWorkingDirectory: String? = {
            guard startupHandlesWorkingDirectory else { return workingDirectory }
            let candidate = tmuxLauncher != nil ? workingDirectory : resumeSessionWorkingDirectory
            return OneShotTerminalLauncherStore.enterableWorkingDirectory(candidate)
        }()
        let shouldReplayScrollback = policy.shouldReplaySessionScrollback(
            hasRestorableAgent: restorableAgent != nil,
            tmuxStartCommand: restoredTmuxStartCommand,
            hasResumeStartupWork: bindingLaunch != nil || agentLaunch != nil
        )
        let restoredScrollback = shouldReplayScrollback ? terminalSnapshot.scrollback : nil
        let replayFileURL = SessionScrollbackReplayStore.replayFileURL(for: restoredScrollback)
        let replayEnvironment = SessionScrollbackReplayStore.replayEnvironment(forFileURL: replayFileURL)
        let reusableSurfaceId = GhosttyApp.terminalSurfaceRegistry.surface(id: snapshot.id) == nil
            ? snapshot.id
            : UUID()
        let terminal = TerminalPanel(
            id: reusableSurfaceId,
            workspaceId: workspaceId,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: TerminalFontSizeCreationPolicy.sessionRestore(
                overrideBasePoints: terminalSnapshot.fontSize,
                representedChangeTokens: Set(
                    terminalSnapshot.fontSizeChangeTokens ?? []
                )
            ).applying(to: nil),
            // Start the owning shell in the resume cwd when it is currently
            // enterable so exiting the child launcher preserves #7031. The
            // launcher still owns the authoritative guard for missing,
            // inaccessible, or concurrently changed directories.
            workingDirectory: hostShellWorkingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: restoredTmuxStartCommand,
            initialInput: initialInput,
            additionalEnvironment: replayEnvironment,
            focusPlacement: .rightSidebarDock,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        terminal.adoptOwnedSessionScrollbackReplayArtifact(replayFileURL)
        terminal.restoreSessionTextBoxDraft(terminalSnapshot.textBoxDraft)

        guard attachSessionRestoredPanel(terminal, snapshot: snapshot, inPane: paneId) != nil else {
            if let replayFileURL { try? FileManager.default.removeItem(at: replayFileURL) }
            if agentLaunch != nil, let restorableAgent {
                AgentResumeLaunchGuard.shared.releaseResumeLaunch(
                    kind: restorableAgent.kind.rawValue,
                    sessionId: restorableAgent.sessionId
                )
            }
            return nil
        }
        if let stableSurfaceId = snapshot.stableSurfaceId,
           !excludingStableIdentities.contains(stableSurfaceId) {
            terminal.adoptStableSurfaceId(stableSurfaceId)
        }
        if let resumeBinding {
            surfaceResumeBindingsByPanelId[terminal.id] = resumeBinding
        }
        if let managedResumeBinding {
            managedAgentResumeBindingsByPanelId[terminal.id] = managedResumeBinding
        }
        if let restoredScrollback {
            restoredTerminalScrollbackByPanelId[terminal.id] = restoredScrollback
        }
        let willRunAgentCommand = false
        let willRunAgentInput =
            agentLaunch?.initialInput != nil ||
            (bindingLaunch?.initialInput != nil && resumeBinding?.isAgentHookBinding == true)
        seedSessionRestoredAgentState(
            panelId: terminal.id,
            restorableAgent: restorableAgent,
            resumeBinding: managedResumeBinding ?? resumeBinding,
            willRunStartupCommand: willRunAgentCommand,
            willRunStartupInput: willRunAgentInput
        )
        if let hibernation, let restorableAgent, restorableAgent.resumeCommand != nil {
            terminal.enterAgentHibernation(
                agent: restorableAgent,
                lastActivityAt: Date(timeIntervalSince1970: hibernation.lastActivityAt),
                hibernatedAt: Date(timeIntervalSince1970: hibernation.hibernatedAt)
            )
        }
        if willRunAgentCommand || willRunAgentInput,
           let resumeSessionWorkingDirectory {
            restoredResumeSessionWorkingDirectoriesByPanelId[terminal.id] = resumeSessionWorkingDirectory
        }
        recordSessionResumeIntent(
            panelId: terminal.id,
            restorableAgent: restorableAgent,
            resumeBinding: resumeBinding,
            workingDirectory: resumeSessionWorkingDirectory,
            agentSessionAlreadyActive: agentSessionAlreadyActive
        )
        return terminal.id
    }

    private func restoreSessionBrowser(
        from snapshot: SessionPanelSnapshot,
        inPane paneId: PaneID,
        excludingStableIdentities: Set<UUID>
    ) -> UUID? {
        guard let browserSnapshot = snapshot.browser, isBrowserAvailable() else {
            return nil
        }
        let browser = makeBrowserPanel(
            url: nil,
            preferredProfileID: browserSnapshot.profileID,
            transparentBackground: browserSnapshot.transparentBackground ?? false
        )
        guard attachSessionRestoredPanel(browser, snapshot: snapshot, inPane: paneId) != nil else {
            return nil
        }
        if let stableSurfaceId = snapshot.stableSurfaceId,
           !excludingStableIdentities.contains(stableSurfaceId) {
            browser.adoptStableSurfaceId(stableSurfaceId)
        }
        let pageZoom = CGFloat(max(0.25, min(5, browserSnapshot.pageZoom)))
        if pageZoom.isFinite { _ = browser.setPageZoomFactor(pageZoom) }
        browser.restoreSessionSnapshot(browserSnapshot)
        if browserSnapshot.developerToolsVisible {
            _ = browser.showDeveloperTools()
            browser.requestDeveloperToolsRefreshAfterNextAttach(reason: "session_restore")
        } else {
            _ = browser.hideDeveloperTools()
        }
        return browser.id
    }

    @discardableResult
    private func attachSessionRestoredPanel(
        _ panel: any Panel,
        snapshot: SessionPanelSnapshot,
        inPane paneId: PaneID
    ) -> TabID? {
        panels[panel.id] = panel
        let title = snapshot.customTitle ?? snapshot.title ?? panel.displayTitle
        guard let tabId = bonsplitController.createTab(
            title: title,
            hasCustomTitle: snapshot.customTitle != nil,
            icon: panel.displayIcon,
            kind: panel.panelType == .browser ? "browser" : "terminal",
            isDirty: panel.isDirty,
            isLoading: (panel as? BrowserPanel)?.isLoading ?? false,
            isAudioMuted: (panel as? BrowserPanel)?.isMuted ?? false,
            isPinned: false,
            inPane: paneId
        ) else {
            discardPanelOwnershipAndClose(panelId: panel.id)
            return nil
        }
        surfaceIdToPanelId[tabId] = panel.id
        installSubscription(for: panel, tracksTerminalTitle: true)
        applyVisibility(to: panel)
        return tabId
    }

    private func focusDockController(panelId: UUID) {
        guard let paneId = paneId(forPanelId: panelId),
              let tabId = surfaceId(forPanelId: panelId) else { return }
        bonsplitController.focusPane(paneId)
        bonsplitController.selectTab(tabId)
    }

    private func seedSessionRestoredAgentState(
        panelId: UUID,
        restorableAgent: SessionRestorableAgentSnapshot?,
        resumeBinding: SurfaceResumeBindingSnapshot?,
        willRunStartupCommand: Bool,
        willRunStartupInput: Bool
    ) {
        restoredAgentLifecycle.snapshotsByPanelId[panelId] = restorableAgent
        if willRunStartupCommand {
            restoredAgentLifecycle.resumeStatesByPanelId[panelId] = .autoResumeCommandRunning
        } else if willRunStartupInput {
            restoredAgentLifecycle.resumeStatesByPanelId[panelId] = .awaitingAutoResumeCommand
        } else if restorableAgent != nil || resumeBinding?.isAgentHookBinding == true {
            restoredAgentLifecycle.resumeStatesByPanelId[panelId] = .manualResumeAvailable
        } else {
            restoredAgentLifecycle.resumeStatesByPanelId.removeValue(forKey: panelId)
        }
    }

    private func sessionAgentAlreadyActive(
        restorableAgent: SessionRestorableAgentSnapshot?,
        snapshotPanelId: UUID,
        shouldAutoResume: Bool
    ) -> Bool {
        guard shouldAutoResume, let restorableAgent else { return false }
        let index = SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh()
            ?? RestorableAgentSessionIndex.load()
        if AgentResumeLiveness.hasLiveProcess(
            for: index.entry(workspaceId: workspaceId, panelId: snapshotPanelId),
            kind: restorableAgent.kind.rawValue,
            sessionId: restorableAgent.sessionId
        ) {
            return true
        }
        return !AgentResumeLaunchGuard.shared.claimResumeLaunch(
            kind: restorableAgent.kind.rawValue,
            sessionId: restorableAgent.sessionId
        )
    }

    private func recordSessionResumeIntent(
        panelId: UUID,
        restorableAgent: SessionRestorableAgentSnapshot?,
        resumeBinding: SurfaceResumeBindingSnapshot?,
        workingDirectory: String?,
        agentSessionAlreadyActive: Bool
    ) {
        guard !agentSessionAlreadyActive else { return }
        let session: (id: String, source: String)? = if let restorableAgent {
            (restorableAgent.sessionId, restorableAgent.kind.rawValue)
        } else if resumeBinding?.isAgentHookBinding == true,
                  let id = resumeBinding?.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty,
                  let source = resumeBinding?.kind?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !source.isEmpty {
            (id, source)
        } else {
            nil
        }
        guard let session else { return }
        AgentChatTranscriptService.recordResumeIntent(
            sessionID: session.id,
            source: session.source,
            surfaceID: panelId.uuidString,
            workspaceID: workspaceId.uuidString,
            workingDirectory: workingDirectory
        )
#if DEBUG
        cmuxDebugLog("session.restore.dock.resumeBinding workspace=\(workspaceId.uuidString.prefix(8)) surface=\(panelId.uuidString.prefix(8)) source=\(session.source) session=\(session.id.prefix(8))")
#endif
    }
}
