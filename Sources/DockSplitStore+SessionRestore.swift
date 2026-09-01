import Bonsplit
import CmuxTerminal
import CmuxTerminalCore
import CmuxWorkspaces
import Foundation

extension DockSplitStore {
    /// Returns Dock panels that remained visible because automatic restore was unsafe.
    func sessionRestoreRecoveryInventoryItems(
        notificationTabID: UUID
    ) -> [SessionRestoreRecoveryInventoryItem] {
        restoredAgentLifecycle.recoveryNeededWorkingDirectoriesByPanelId.map {
            panelID, savedWorkingDirectory in
            SessionRestoreRecoveryInventoryItem(
                tabID: notificationTabID,
                panelID: panelID,
                savedWorkingDirectory: savedWorkingDirectory,
                snapshot: restoredAgentLifecycle.snapshotsByPanelId[panelID]
            )
        }.sorted { lhs, rhs in
            lhs.panelID.uuidString < rhs.panelID.uuidString
        }
    }

    /// Restores Dock topology and panel state from a persisted split snapshot.
    ///
    /// Browser panels can remain lightweight until their host reports visibility;
    /// terminal restore ownership is still validated through the supplied agent index.
    @discardableResult
    func restoreSessionSnapshot(
        _ snapshot: SessionSplitContainerSnapshot,
        excludingStableIdentities: Set<UUID> = [],
        deferBrowserPanels: Bool = false,
        sourceWorkspaceResolver: (UUID) -> Workspace? = { _ in nil }
    ) -> [UUID: UUID] {
        guard !isRetired else { return [:] }
        sessionRestoreDepth += 1
        defer {
            sessionRestoreDepth = max(sessionRestoreDepth - 1, 0)
            if sessionRestoreDepth == 0 {
                let pendingPanelIds = pendingDeferredBrowserMaterializationPanelIds
                pendingDeferredBrowserMaterializationPanelIds.removeAll()
                for panelId in pendingPanelIds {
                    _ = requestDeferredBrowserMaterialization(
                        panelId: panelId,
                        isVisibleInUI: panelIsSelectedInVisibleDockPane(panelId),
                        reason: "dock.sessionRestore.complete"
                    )
                }
            }
        }
        cancelConfigurationTasks()
        removeAllPanels()
        hasLoadedConfiguration = true
        hasAppliedConfigurationSeed = true

        let layoutCodec = SessionSplitContainerLayoutCodec(controller: bonsplitController)
        let scaffold = withProgrammaticDockSplit { layoutCodec.restoreScaffold(snapshot.layout) }
        let panelSnapshotsById = Dictionary(uniqueKeysWithValues: snapshot.panels.map { ($0.id, $0) })
        let restorableAgentIndex = restoreAgentIndex(for: snapshot.panels)
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
                          sourceWorkspaceResolver: sourceWorkspaceResolver,
                          deferBrowserPanel: deferBrowserPanels,
                          restorableAgentIndex: restorableAgentIndex
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
        terminalStartupRestoreCoordinator.commitPendingRestores(
            panelIDs: Array(oldToNewPanelIds.values)
        )
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
        let restorableAgentIndex = restoreAgentIndex(for: [snapshot])
        let restoredPanelId = createSessionRestoredPanel(
            from: snapshot,
            inPane: paneId,
            excludingStableIdentities: [],
            sourceWorkspaceId: sourceWorkspaceId,
            sourceSnapshotWorkspaceId: sourceSnapshotWorkspaceId,
            sourceWorkspaceResolver: sourceWorkspaceResolver,
            restorableAgentIndex: restorableAgentIndex
        )
        if let restoredPanelId {
            terminalStartupRestoreCoordinator.commitPendingRestores(
                panelIDs: [restoredPanelId]
            )
        }
        return restoredPanelId
    }

    private func createSessionRestoredPanel(
        from snapshot: SessionPanelSnapshot,
        inPane paneId: PaneID,
        excludingStableIdentities: Set<UUID>,
        sourceWorkspaceId: UUID?,
        sourceSnapshotWorkspaceId: UUID?,
        sourceWorkspaceResolver: (UUID) -> Workspace?,
        deferBrowserPanel: Bool = false,
        restorableAgentIndex: RestorableAgentSessionIndex? = nil
    ) -> UUID? {
        if (!deferBrowserPanel || snapshot.type != .browser),
           let sourceWorkspaceId,
           let sourceWorkspace = sourceWorkspaceResolver(sourceWorkspaceId),
           let detached = sourceWorkspace.detachedSurfaceForDockSessionRestore(
               snapshot,
               snapshotWorkspaceId:
                sourceSnapshotWorkspaceId ?? sourceWorkspaceId,
               excludingStableIdentities: excludingStableIdentities,
               restorableAgentIndex: restorableAgentIndex
           ) {
            let restoredPanelId = attachDetachedSurface(detached, inPane: paneId, focus: false)
            if let restoredPanelId {
                sourceWorkspace.terminalStartupRestoreCoordinator.transferPendingRestore(
                    panelID: restoredPanelId,
                    to: terminalStartupRestoreCoordinator
                )
            } else {
                let cancelledRestore = sourceWorkspace
                    .terminalStartupRestoreCoordinator
                    .cancelPendingRestore(panelID: detached.panelId)
                // Browser and other non-startup transfers have no restore transaction.
                if !cancelledRestore { detached.panel.close() }
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
                excludingStableIdentities: excludingStableIdentities,
                restorableAgentIndex: restorableAgentIndex
            )
        case .browser:
            if deferBrowserPanel,
               snapshot.browser != nil,
               isBrowserAvailable() {
                let restoredPanelId = panels[snapshot.id] == nil ? snapshot.id : UUID()
                let deferredPanel = DeferredBrowserPanel(
                    id: restoredPanelId,
                    workspaceId: workspaceId,
                    snapshot: snapshot
                )
                guard attachSessionRestoredPanel(
                    deferredPanel,
                    snapshot: snapshot,
                    inPane: paneId
                ) != nil else {
                    return nil
                }
                if let stableSurfaceId = snapshot.stableSurfaceId,
                   !excludingStableIdentities.contains(stableSurfaceId) {
                    deferredPanel.adoptStableSurfaceId(stableSurfaceId)
                }
                return restoredPanelId
            }
            return restoreSessionBrowser(
                from: snapshot,
                inPane: paneId,
                excludingStableIdentities: excludingStableIdentities
            )
        case .filePreview:
            return restoreSessionFilePreview(
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
        excludingStableIdentities: Set<UUID>,
        restorableAgentIndex: RestorableAgentSessionIndex?
    ) -> UUID? {
        let snapshot = Workspace.repairedLegacyHermesSessionPanelSnapshot(
            snapshot,
            workspaceId: workspaceId
        )
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
        // A persisted agent snapshot can coexist with a non-agent binding
        // (for example, a process-detected tmux attach). Keep that snapshot
        // available for manual continuation, but do not synthesize an agent
        // resume command on top of the non-agent startup path.
        let restorableAgentCanAutoResume = restorableAgent != nil &&
            (resumeBinding == nil || resumeBinding?.isAgentHookBinding == true)
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
        let shouldCheckAgentOwnership = shouldAutoResumeAgent &&
            (restorableAgentCanAutoResume || resumeBinding?.isAgentHookBinding == true)
        let restoreAgentIndex = shouldCheckAgentOwnership ? restorableAgentIndex : nil
        let restoreIndexUnavailable = shouldCheckAgentOwnership && restoreAgentIndex == nil
        let expectedAgentKind = restorableAgent?.kind.rawValue ?? resumeBinding?.kind
        let expectedSessionId = restorableAgent?.sessionId ?? resumeBinding?.checkpointId
        let stablePanelHasLiveProcess = restoreAgentIndex?.hasCurrentLiveProcessForStablePanel(
            workspaceId: workspaceId,
            panelId: snapshot.id,
            revalidateProcessEvidence: false
        ) == true
        let stablePanelHasConflictingLiveProcess = restoreAgentIndex?.hasConflictingLiveStablePanelEntry(
            workspaceId: workspaceId,
            panelId: snapshot.id,
            expectedKind: expectedAgentKind,
            expectedSessionId: expectedSessionId,
            revalidateProcessEvidence: false
        ) == true
        let stablePanelHasUncertainProcess = restoreAgentIndex?.hasUncertainStablePanelEntry(
            panelId: snapshot.id,
            revalidateProcessEvidence: false
        ) == true
        let restoreOwnershipAmbiguous = shouldCheckAgentOwnership && (
            stablePanelHasConflictingLiveProcess ||
            restoreAgentIndex?.hasAmbiguousPanel(snapshot.id) == true ||
            (restoreAgentIndex?.hasCurrentAmbiguousPanel(
                snapshot.id,
                revalidateProcessEvidence: false
            ) == true)
        )
        let restoreStartupBlocked = restoreIndexUnavailable || restoreOwnershipAmbiguous ||
            stablePanelHasUncertainProcess
        let resumeBindingForStartup = hibernation != nil ||
            restoreStartupBlocked ||
            stablePanelHasLiveProcess ||
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
        let unresolvedBindingLaunch = restoreStartupBlocked || stablePanelHasLiveProcess
            ? nil
            : approvedResumeBinding.flatMap {
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
        let tmuxStartCommand = !restoreStartupBlocked && !stablePanelHasLiveProcess &&
            restorableAgent == nil && bindingLaunch == nil
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
            shouldAutoResume: shouldAutoResumeAgent && restorableAgentCanAutoResume &&
                hibernation == nil && bindingLaunch == nil,
            liveIndex: restoreAgentIndex,
            restoreStartupBlocked: restoreStartupBlocked
        )
        let agentLaunch = shouldAutoResumeAgent && restorableAgentCanAutoResume &&
            hibernation == nil && bindingLaunch == nil
            && !agentSessionAlreadyActive
            ? restorableAgent?.resumeStartupInput(
                restoringWorkingDirectory: resumeSessionWorkingDirectory
            ).map(WorkspaceSurfaceResumeStartupLaunch.input)
            : nil
        // Build the candidate before arming the gate. A binding that is
        // disabled, unapproved, or cannot render a command must start as an
        // ordinary shell instead of waiting behind deferred admission.
        let deferredAgentResumeCandidateInput: String? = if restoreIndexUnavailable,
            hibernation == nil,
            restorableAgentCanAutoResume || resumeBinding?.isAgentHookBinding == true {
            if let restorableAgent, restorableAgentCanAutoResume {
                restorableAgent.resumeStartupInput(
                    restoringWorkingDirectory: resumeSessionWorkingDirectory
                )
            } else {
                policy
                    .approvedSurfaceResumeBinding(
                        resumeBinding,
                        autoResumeAgentSessions: shouldAutoResumeAgent,
                        promptForApproval: true,
                        approvalStoreURL: SurfaceResumeApprovalStore.defaultURL()
                    )
                    .flatMap {
                        policy.surfaceResumeStartupLaunch(forApprovedBinding: $0)?.initialInput
                    }
            }
        } else {
            nil
        }
        let deferredAgentResumeStartupInput = deferredAgentResumeCandidateInput?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty == false ? deferredAgentResumeCandidateInput : nil
        let deferredAgentResumeAdmission = deferredAgentResumeStartupInput != nil
        let initialCommand = tmuxLauncher
        let initialInput = bindingLaunch?.initialInput ??
            agentLaunch?.initialInput ??
            deferredAgentResumeStartupInput
        let willRunAgentInput =
            agentLaunch?.initialInput != nil ||
            (bindingLaunch?.initialInput != nil && resumeBinding?.isAgentHookBinding == true) ||
            deferredAgentResumeStartupInput != nil
        let startupHandlesWorkingDirectory =
            tmuxLauncher != nil || agentLaunch != nil || bindingLaunch != nil ||
            deferredAgentResumeStartupInput != nil
        let hostShellWorkingDirectory: String? = {
            guard startupHandlesWorkingDirectory else { return workingDirectory }
            let candidate = tmuxLauncher != nil ? workingDirectory : resumeSessionWorkingDirectory
            return OneShotTerminalLauncherStore.enterableWorkingDirectory(candidate)
        }()
        let shouldReplayScrollback = policy.shouldReplaySessionScrollback(
            hasRestorableAgent: restorableAgent != nil,
            tmuxStartCommand: restoredTmuxStartCommand,
            hasResumeStartupWork: bindingLaunch != nil || agentLaunch != nil ||
                deferredAgentResumeStartupInput != nil
        )
        let restoredScrollback = shouldReplayScrollback ? terminalSnapshot.scrollback : nil
        let replayFileURL = SessionScrollbackReplayStore.replayFileURL(for: restoredScrollback)
        let replayEnvironment = SessionScrollbackReplayStore.replayEnvironment(forFileURL: replayFileURL)
        let reusableSurfaceId = GhosttyApp.terminalSurfaceRegistry.surface(id: snapshot.id) == nil
            ? snapshot.id
            : UUID()
        // A rebuilt shell must not inherit socket-report dedupe state from a
        // closed surface whose persisted ID it is reusing.
        TerminalController.shared.cleanupSurfaceState(
            surfaceIds: [reusableSurfaceId],
            workspaceID: workspaceId
        )
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
            runtimeSpawnPolicy: terminalStartupRestoreCoordinator.runtimeSpawnPolicy(
                requestedPolicy: .pacedSessionRestore,
                willRunStartupCommand: false,
                willRunStartupInput: willRunAgentInput,
                awaitsDeferredAgentResume: deferredAgentResumeAdmission
            )
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
        armRestoredPanelTitleBoundary(
            panelId: terminal.id,
            internallySeededInput: initialInput
        )
        if let stableSurfaceId = snapshot.stableSurfaceId,
           !excludingStableIdentities.contains(stableSurfaceId) {
            terminal.adoptStableSurfaceId(stableSurfaceId)
        }
        if let resumeBinding {
            if surfaceResumeBindingMutationAllowed(resumeBinding, panelId: terminal.id) {
                surfaceResumeBindingsByPanelId[terminal.id] = resumeBinding
            }
        }
        if let managedResumeBinding {
            managedAgentResumeBindingsByPanelId[terminal.id] = managedResumeBinding
        }
        if let restoredScrollback {
            restoredTerminalScrollbackByPanelId[terminal.id] = restoredScrollback
        }
        terminalStartupRestoreCoordinator.stage(
            panel: terminal,
            snapshot: restorableAgent,
            resumeBinding: resumeBinding,
            manualResumeAvailable: restorableAgent != nil ||
                (managedResumeBinding ?? resumeBinding)?.isAgentHookBinding == true,
            willRunStartupCommand: false,
            willRunStartupInput: willRunAgentInput,
            resumeWorkingDirectory: resumeSessionWorkingDirectory,
            agentSessionAlreadyActive: deferredAgentResumeAdmission
                ? true
                : (restoreIndexUnavailable ? false : agentSessionAlreadyActive),
            ownsResumeLaunchClaim: agentLaunch != nil,
            defersStartupRestoreAdmission: deferredAgentResumeAdmission
        )
        if deferredAgentResumeAdmission {
            deferAgentResumeRestore(
                panelId: terminal.id,
                restore: DeferredAgentResumeRestore(
                    stablePanelID: snapshot.id,
                    restorableAgent: restorableAgent,
                    resumeBinding: resumeBinding,
                    restoresRemoteWorkspaceTerminalSnapshot: false,
                    remoteResumeContext: resumeBinding?.launchFlavor.remoteContext,
                    workingDirectory: workingDirectory,
                    resumeWorkingDirectory: resumeSessionWorkingDirectory
                )
            )
        }
        if let hibernation, let restorableAgent, restorableAgent.resumeCommand != nil {
            terminal.enterAgentHibernation(
                agent: restorableAgent,
                lastActivityAt: Date(timeIntervalSince1970: hibernation.lastActivityAt),
                hibernatedAt: Date(timeIntervalSince1970: hibernation.hibernatedAt)
            )
        }
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

    /// Materializes a browser that was kept as a lightweight restore placeholder.
    @discardableResult
    func materializeDeferredBrowserPanel(_ deferredPanel: DeferredBrowserPanel) -> BrowserPanel? {
        guard panels[deferredPanel.id] === deferredPanel,
              let browserSnapshot = deferredPanel.sessionPanelSnapshot.browser,
              !isRetired else {
            return panels[deferredPanel.id] as? BrowserPanel
        }

        let browser = makeBrowserPanel(
            id: deferredPanel.id,
            url: nil,
            preferredProfileID: browserSnapshot.profileID,
            renderInitialNavigation: false,
            chromeVisibility: browserSnapshot.chromeVisibility ?? .visible,
            transparentBackground: browserSnapshot.transparentBackground ?? false
        )
        browser.adoptStableSurfaceId(deferredPanel.stableSurfaceIdentity.id)
        panels[deferredPanel.id] = browser
        let pageZoom = CGFloat(max(0.25, min(5, browserSnapshot.pageZoom)))
        if pageZoom.isFinite {
            _ = browser.setPageZoomFactor(pageZoom)
        }
        browser.restoreSessionSnapshot(browserSnapshot)
        if browserSnapshot.developerToolsVisible {
            _ = browser.showDeveloperTools()
            browser.requestDeveloperToolsRefreshAfterNextAttach(reason: "session_restore")
        } else {
            _ = browser.hideDeveloperTools()
        }
        installSubscription(for: browser)
        if let tabId = surfaceId(forPanelId: deferredPanel.id) {
            bonsplitController.updateTab(
                tabId,
                icon: .some(browser.displayIcon),
                kind: .some(Self.surfaceKind(for: browser)),
                isLoading: browser.isLoading,
                isAudioMuted: browser.isMuted,
                isAudioPlaying: browser.isPlayingAudio
            )
        }
        applyVisibility(to: browser)
        scheduleDockPortalReconcile(reason: "dock.browserMaterialize")
#if DEBUG
        cmuxDebugLog(
            "session.restore.dockBrowser.materialize dock=\(workspaceId.uuidString.prefix(8)) " +
                "panel=\(deferredPanel.id.uuidString.prefix(8))"
        )
#endif
        return browser
    }

    /// Recreates one persisted file-preview panel in its restored Dock pane.
    private func restoreSessionFilePreview(
        from snapshot: SessionPanelSnapshot,
        inPane paneId: PaneID,
        excludingStableIdentities: Set<UUID>
    ) -> UUID? {
        guard let filePath = snapshot.filePreview?.filePath else { return nil }
        let panel = FilePreviewPanel(workspaceId: workspaceId, filePath: filePath)
        guard attachSessionRestoredPanel(
            panel,
            snapshot: snapshot,
            inPane: paneId
        ) != nil else {
            return nil
        }
        if let stableSurfaceId = snapshot.stableSurfaceId,
           !excludingStableIdentities.contains(stableSurfaceId) {
            panel.adoptStableSurfaceId(stableSurfaceId)
        }
        return panel.id
    }

    @discardableResult
    private func attachSessionRestoredPanel(
        _ panel: any Panel,
        snapshot: SessionPanelSnapshot,
        inPane paneId: PaneID
    ) -> TabID? {
        guard !isRetired else {
            panel.close()
            return nil
        }
        panels[panel.id] = panel
        let title = snapshot.customTitle ?? snapshot.title ?? panel.displayTitle
        let isAudioMuted = resolvedAudioMuted(for: panel)
        guard let tabId = bonsplitController.createTab(
            title: title,
            hasCustomTitle: snapshot.customTitle != nil,
            icon: panel.displayIcon,
            kind: Self.surfaceKind(for: panel),
            isDirty: panel.isDirty,
            showsNotificationBadge: snapshot.isManuallyUnread,
            isLoading: (panel as? BrowserPanel)?.isLoading ?? false,
            isAudioMuted: isAudioMuted,
            isPinned: snapshot.isPinned,
            inPane: paneId
        ) else {
            discardPanelOwnershipAndClose(panelId: panel.id)
            return nil
        }
        bindSurface(tabId, toPanelId: panel.id)
        adoptManualUnreadState(
            snapshot.isManuallyUnread,
            panelId: panel.id
        )
        installSubscription(for: panel)
        applyVisibility(to: panel)
        return tabId
    }

    private func focusDockController(panelId: UUID) {
        guard let paneId = paneId(forPanelId: panelId),
              let tabId = surfaceId(forPanelId: panelId) else { return }
        bonsplitController.focusPane(paneId)
        bonsplitController.selectTab(tabId)
    }

    private func sessionAgentAlreadyActive(
        restorableAgent: SessionRestorableAgentSnapshot?,
        snapshotPanelId: UUID,
        shouldAutoResume: Bool,
        liveIndex: RestorableAgentSessionIndex?,
        restoreStartupBlocked: Bool
    ) -> Bool {
        guard shouldAutoResume, let restorableAgent else { return false }
        if restoreStartupBlocked {
            // The off-main index refresh will resolve this staged panel.
            return true
        }
        guard let index = liveIndex else { return true }
        if index.hasCurrentAmbiguousPanel(
            snapshotPanelId,
            revalidateProcessEvidence: false
        ) {
            // Unknown ownership is safer than launching a duplicate agent against a
            // session that may still be live under another restored owner.
            return true
        }
        if index.hasCurrentLiveProcessForStablePanel(
            workspaceId: workspaceId,
            panelId: snapshotPanelId,
            expectedKind: restorableAgent.kind.rawValue,
            expectedSessionId: restorableAgent.sessionId,
            revalidateProcessEvidence: false
        ) {
            return true
        }
        return !AgentResumeLaunchGuard.shared.claimResumeLaunch(
            kind: restorableAgent.kind.rawValue,
            sessionId: restorableAgent.sessionId
        )
    }

    private func restoreAgentIndex(
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
        // Ownership-sensitive restore decisions use the injected authoritative
        // index, or defer launch until the off-main refresh completes.
        return restorableAgentIndexProvider()
    }

}
