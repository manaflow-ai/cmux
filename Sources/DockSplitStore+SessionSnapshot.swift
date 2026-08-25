import Bonsplit
import CmuxWorkspaces
import Darwin
import Foundation

extension DockSplitStore {
    func sessionSnapshot(
        includeScrollback: Bool,
        restorableAgentIndex: RestorableAgentSessionIndex? = nil,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil,
        currentAgentProcessIdentity: (Int) -> AgentPIDProcessIdentity? = {
            guard $0 > 0, $0 <= Int(Int32.max) else { return nil }
            return AgentPIDProcessIdentity(pid: pid_t($0))
        },
        agentProcessPresence: (Int) -> PIDPresence = {
            guard $0 > 0, $0 <= Int(Int32.max) else { return .absent }
            return PIDPresence.current(pid: pid_t($0))
        }
    ) -> SessionSplitContainerSnapshot {
        flushPendingTerminalTitleUpdates()
        let notificationStore = resolvedNotificationStore()
        let layoutCodec = SessionSplitContainerLayoutCodec(controller: bonsplitController)
        let rawLayout = layoutCodec.snapshot(panelIdForTabId: { [self] in surfaceIdToPanelId[$0] })
        let orderedPanelIds = orderedSessionPanelIds()
        let terminalPanelIds = Set(
            orderedPanelIds.filter {
                panels[$0] is TerminalPanel
            }
        )
        let terminalFontSizeSnapshotProjection: WorkspaceTerminalFontSizeSnapshotProjection?
        if let workspace = terminalFontSizeOwningWorkspace {
            terminalFontSizeSnapshotProjection =
                terminalFontSizeChangeArbiter?
                    .snapshotProjection(
                        for: workspace,
                        panelIds: terminalPanelIds
                    )
        } else {
            terminalFontSizeSnapshotProjection =
                terminalFontSizeChangeArbiter?
                    .snapshotProjection(
                        for: self,
                        panelIds: terminalPanelIds
                    )
        }
        let panelSnapshots = orderedPanelIds
            .prefix(SessionPersistencePolicy.maxPanelsPerWorkspace)
            .compactMap { panelId in
                // A Dock's owner UUID can change when its window/workspace is restored or
                // when the panel moves between containers. The panel UUID is persisted,
                // so select the newest safe record for that stable surface while preserving
                // live process evidence for the current owner.
                let observationWorkspaceId = detachedSurfaceTransfersByPanelId[panelId]?
                    .sessionRestoreWorkspaceId ?? workspaceId
                return sessionPanelSnapshot(
                    panelId: panelId,
                    includeScrollback: includeScrollback,
                    observation: restorableAgentIndex?.entryForStablePanel(
                        workspaceId: observationWorkspaceId,
                        panelId: panelId,
                        processIdentityProvider: currentAgentProcessIdentity,
                        processPresenceProvider: agentProcessPresence
                    ),
                    detectedResumeBinding: surfaceResumeBindingIndex?.bindingForStablePanel(
                        workspaceId: observationWorkspaceId,
                        panelId: panelId
                    ),
                    terminalFontSizeSnapshotProjection:
                        terminalFontSizeSnapshotProjection,
                    notificationStore: notificationStore,
                    currentAgentProcessIdentity: currentAgentProcessIdentity,
                    agentProcessPresence: agentProcessPresence
                )
            }
        let persistedPanelIds = Set(panelSnapshots.map(\.id))
        let sourceWorkspaceIdsByPanelId: [UUID: UUID] = Dictionary(
            uniqueKeysWithValues: panelSnapshots.compactMap { panel -> (UUID, UUID)? in
                guard let transfer = detachedSurfaceTransfersByPanelId[panel.id] else { return nil }
                return (panel.id, transfer.sessionRestoreWorkspaceId)
            }
        )
        let layout = layoutCodec.pruned(
            rawLayout,
            keeping: persistedPanelIds
        ) ?? .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil))
        return SessionSplitContainerSnapshot(
            focusedPanelId: focusedPanelId.flatMap {
                persistedPanelIds.contains($0) ? $0 : nil
            },
            layout: layout,
            panels: panelSnapshots,
            sourceWorkspaceIdsByPanelId: sourceWorkspaceIdsByPanelId.isEmpty
                ? nil
                : sourceWorkspaceIdsByPanelId
        )
    }

    /// Hashes the manual unread bits persisted for this global Dock's panels.
    func sessionManualUnreadAutosaveFingerprint(
        notificationStore: TerminalNotificationStore?
    ) -> Int {
        self.notificationStore = notificationStore
        var hasher = Hasher()
        let panelIds = Array(
            orderedSessionPanelIds()
                .prefix(SessionPersistencePolicy.maxPanelsPerWorkspace)
        )
        hasher.combine(panelIds.count)
        for panelId in panelIds {
            hasher.combine(panelId)
            hasher.combine(notificationStore?.hasManualUnread(
                forTabId: workspaceId,
                surfaceId: panelId
            ) ?? false)
        }
        return hasher.finalize()
    }

    /// Captures one Dock panel for the Dock-local closed-item history without
    /// walking every other panel in the split tree.
    func closedPanelSessionSnapshot(
        panelId: UUID,
        restorableAgentIndex: RestorableAgentSessionIndex?
    ) -> SessionPanelSnapshot? {
        flushPendingTerminalTitleUpdate(panelId: panelId)
        let transfer = detachedSurfaceTransfersByPanelId[panelId]
        let observationWorkspaceId =
            transfer?.sessionRestoreWorkspaceId ?? workspaceId
        let terminalFontSizeSnapshotProjection:
            WorkspaceTerminalFontSizeSnapshotProjection?
        if panels[panelId] is TerminalPanel {
            if let workspace = terminalFontSizeOwningWorkspace {
                terminalFontSizeSnapshotProjection =
                    terminalFontSizeChangeArbiter?
                        .snapshotProjection(
                            for: workspace,
                            panelIds: [panelId]
                        )
            } else {
                terminalFontSizeSnapshotProjection =
                    terminalFontSizeChangeArbiter?
                        .snapshotProjection(
                            for: self,
                            panelIds: [panelId]
                        )
            }
        } else {
            terminalFontSizeSnapshotProjection = nil
        }

        return sessionPanelSnapshot(
            panelId: panelId,
            includeScrollback: true,
            observation: restorableAgentIndex?.entryForStablePanel(
                workspaceId: observationWorkspaceId,
                panelId: panelId,
                processIdentityProvider: {
                    guard $0 > 0, $0 <= Int(Int32.max) else { return nil }
                    return AgentPIDProcessIdentity(pid: pid_t($0))
                },
                processPresenceProvider: {
                    guard $0 > 0, $0 <= Int(Int32.max) else {
                        return .absent
                    }
                    return PIDPresence.current(pid: pid_t($0))
                }
            ),
            detectedResumeBinding: nil,
            terminalFontSizeSnapshotProjection:
                terminalFontSizeSnapshotProjection,
            notificationStore: resolvedNotificationStore(),
            currentAgentProcessIdentity: {
                guard $0 > 0, $0 <= Int(Int32.max) else { return nil }
                return AgentPIDProcessIdentity(pid: pid_t($0))
            },
            agentProcessPresence: {
                guard $0 > 0, $0 <= Int(Int32.max) else {
                    return .absent
                }
                return PIDPresence.current(pid: pid_t($0))
            }
        )
    }

    private func orderedSessionPanelIds() -> [UUID] {
        var result: [UUID] = []
        var seen: Set<UUID> = []
        for paneId in bonsplitController.allPaneIds {
            for tab in bonsplitController.tabs(inPane: paneId) {
                guard let panelId = surfaceIdToPanelId[tab.id], seen.insert(panelId).inserted else {
                    continue
                }
                result.append(panelId)
            }
        }
        for panelId in panels.keys.sorted(by: { $0.uuidString < $1.uuidString })
        where seen.insert(panelId).inserted {
            result.append(panelId)
        }
        return result
    }

    private func sessionPanelSnapshot(
        panelId: UUID,
        includeScrollback: Bool,
        observation: RestorableAgentSessionIndex.Entry?,
        detectedResumeBinding: SurfaceResumeBindingSnapshot?,
        terminalFontSizeSnapshotProjection:
            WorkspaceTerminalFontSizeSnapshotProjection?,
        notificationStore: TerminalNotificationStore?,
        currentAgentProcessIdentity: (Int) -> AgentPIDProcessIdentity?,
        agentProcessPresence: (Int) -> PIDPresence
    ) -> SessionPanelSnapshot? {
        guard let panel = panels[panelId] else { return nil }
        let transfer = detachedSurfaceTransfersByPanelId[panelId]
        let tab = surfaceId(forPanelId: panelId).flatMap { bonsplitController.tab($0) }
        let titleMetadata = resolvedDockTitleMetadata(
            panel: panel,
            transfer: transfer,
            tab: tab
        )
        let directory = sessionWorkingDirectory(panel: panel, transfer: transfer)
        let isManuallyUnread = scope == .global
            ? notificationStore?.hasManualUnread(
                forTabId: workspaceId,
                surfaceId: panelId
            ) == true
            : manualUnreadPanelIds.contains(panelId)

        let terminalSnapshot: SessionTerminalPanelSnapshot?
        let browserSnapshot: SessionBrowserPanelSnapshot?
        let filePreviewSnapshot: SessionFilePreviewPanelSnapshot?
        switch panel.panelType {
        case .terminal:
            guard let terminal = panel as? TerminalPanel else { return nil }
            let managedResumeBinding = managedAgentResumeBinding(panelId: panelId)
            let resumeBinding = effectiveSessionResumeBinding(
                panelId: panelId,
                detected: detectedResumeBinding
            )
            let restorableAgent = effectiveSessionRestorableAgent(
                panelId: panelId,
                observation: observation,
                resumeBinding: resumeBinding,
                managedResumeBinding: managedResumeBinding,
                terminal: terminal,
                transfer: transfer
            )
            let agentCompatibilityBinding = managedResumeBinding ?? resumeBinding
            let hibernation = terminal.agentHibernationState.flatMap { state in
                Workspace.restorableAgentForSessionRestore(
                    state.agent,
                    resumeBinding: agentCompatibilityBinding
                ) == nil ? nil : state
            }
            let agentWasRunning = sessionAgentWasRunning(
                restorableAgent: restorableAgent,
                resumeBinding: resumeBinding,
                managedResumeBinding: managedResumeBinding,
                terminal: terminal,
                transfer: transfer,
                observation: observation,
                currentAgentProcessIdentity: currentAgentProcessIdentity,
                agentProcessPresence: agentProcessPresence
            )
            let policy = Workspace.makeSessionRestorePolicyService()
            let tmuxStartCommand = restorableAgent == nil
                ? policy.restorableTmuxStartCommand(terminal.surface.debugTmuxStartCommand())
                : nil
            let resumeStartupInput = policy.surfaceResumeStartupInput(
                resumeBinding,
                autoResumeAgentSessions: AgentSessionAutoResumeSettings.isEnabled(
                    defaults: agentSessionAutoResumeDefaults
                ) && (agentWasRunning ?? true),
                promptForApproval: false,
                approvalStoreURL: SurfaceResumeApprovalStore.defaultURL()
            )
            let shouldPersistScrollback = policy.shouldPersistSessionScrollback(
                closeConfirmationRequired: Workspace.resolveCloseConfirmation(
                    shellActivityState: terminal.shellActivity.state,
                    fallbackNeedsConfirmClose: terminal.needsConfirmClose()
                )
            ) && policy.shouldReplaySessionScrollback(
                hasRestorableAgent: restorableAgent != nil,
                tmuxStartCommand: tmuxStartCommand,
                hasResumeStartupWork: resumeStartupInput != nil
            )
            let capturedScrollback = includeScrollback && shouldPersistScrollback && hibernation == nil
                ? TerminalController.shared.readTerminalTextForSnapshot(
                    terminalPanel: terminal,
                    includeScrollback: true,
                    lineLimit: SessionPersistencePolicy.maxScrollbackLinesPerTerminal
                )
                : nil
            let scrollback = policy.resolvedSnapshotTerminalScrollback(
                capturedScrollback: capturedScrollback,
                fallbackScrollback: restoredTerminalScrollbackByPanelId[panelId],
                allowFallbackScrollback: shouldPersistScrollback
            )
            if let scrollback {
                restoredTerminalScrollbackByPanelId[panelId] = scrollback
            }
            let sessionFontSize: Float32?
            let sessionFontSizeChangeTokens: [UUID]?
            if let terminalFontSizeSnapshotProjection {
                let projection =
                    terminalFontSizeSnapshotProjection
                        .sessionProjection(
                            for: terminal
                        )
                sessionFontSize = projection.overrideBasePoints
                sessionFontSizeChangeTokens =
                    projection.persistedRepresentedRequestTokens
            } else {
                sessionFontSize =
                    terminal.surface
                        .sessionFontSizeOverrideBasePoints()
                sessionFontSizeChangeTokens = nil
            }
            terminalSnapshot = SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                fontSize: sessionFontSize,
                fontSizeChangeTokens: sessionFontSizeChangeTokens,
                scrollback: scrollback,
                agent: restorableAgent,
                tmuxStartCommand: tmuxStartCommand,
                hibernation: hibernation.map {
                    SessionAgentHibernationSnapshot(
                        hibernatedAt: $0.hibernatedAt.timeIntervalSince1970,
                        lastActivityAt: $0.lastActivityAt.timeIntervalSince1970
                    )
                },
                resumeBinding: resumeBinding,
                managedAgentResumeBinding: managedResumeBinding,
                textBoxDraft: terminal.sessionTextBoxDraftSnapshot(),
                isRemoteTerminal: transfer?.isRemoteTerminal ?? false,
                remotePTYSessionID: transfer?.remotePTYSessionID,
                wasAgentRunning: agentWasRunning
            )
            browserSnapshot = nil
            filePreviewSnapshot = nil
        case .browser:
            guard let browser = panel as? BrowserPanel, browser.shouldPersistSessionSnapshot() else {
                return nil
            }
            let history = browser.sessionNavigationHistorySnapshot()
            let diffViewer = browser.diffViewerSessionComponents()
            terminalSnapshot = nil
            browserSnapshot = SessionBrowserPanelSnapshot(
                urlString: browser.preferredURLStringForSessionSnapshot(),
                profileID: browser.profileID,
                shouldRenderWebView: browser.shouldRenderWebViewForSessionSnapshot(),
                pageZoom: Double(browser.currentPageZoomFactor()),
                developerToolsVisible: browser.isDeveloperToolsVisible(),
                isMuted: browser.isMuted,
                chromeVisibility: browser.chromeVisibility,
                omnibarVisible: browser.isOmnibarVisible,
                backHistoryURLStrings: history.backHistoryURLStrings,
                forwardHistoryURLStrings: history.forwardHistoryURLStrings,
                transparentBackground: browser.sessionSnapshotTransparentBackground,
                diffViewerToken: diffViewer?.token,
                diffViewerRequestPath: diffViewer?.requestPath
            )
            filePreviewSnapshot = nil
        case .filePreview:
            guard let filePreview = panel as? FilePreviewPanel else {
                return nil
            }
            terminalSnapshot = nil
            browserSnapshot = nil
            filePreviewSnapshot = SessionFilePreviewPanelSnapshot(
                filePath: filePreview.filePath
            )
        default:
            return nil
        }

        return SessionPanelSnapshot(
            id: panelId,
            stableSurfaceId: panel.stableSurfaceId,
            type: panel.panelType,
            title: titleMetadata.title,
            customTitle: titleMetadata.customTitle,
            customTitleSource: titleMetadata.customTitleSource,
            directory: directory,
            directoryIsTrustedRemoteReport: transfer?.directoryIsTrustedRemoteReport,
            isPinned: tab?.isPinned ?? transfer?.isPinned ?? false,
            isManuallyUnread: isManuallyUnread,
            listeningPorts: [],
            ttyName: transfer?.ttyName,
            terminal: terminalSnapshot,
            browser: browserSnapshot,
            markdown: nil,
            filePreview: filePreviewSnapshot,
            rightSidebarTool: nil
        )
    }

    private func sessionWorkingDirectory(
        panel: any Panel,
        transfer: Workspace.DetachedSurfaceTransfer?
    ) -> String? {
        if transfer?.isRemoteTerminal != true,
           let terminal = panel as? TerminalPanel,
           let pid = terminal.surface.foregroundProcessID(),
           let liveDirectory = Workspace.processCurrentWorkingDirectory(pid: Int32(clamping: pid)) {
            return liveDirectory
        }
        if let directory = transfer?.directory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty {
            return directory
        }
        if let directory = (panel as? TerminalPanel)?.requestedWorkingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
            return directory
        }
        return nil
    }

    private func effectiveSessionResumeBinding(
        panelId: UUID,
        detected: SurfaceResumeBindingSnapshot?
    ) -> SurfaceResumeBindingSnapshot? {
        let stored = surfaceResumeBindingsByPanelId[panelId]
        if let stored,
           stored.hasCompleteManagedSessionIdentity,
           managedAgentResumeBindingsByPanelId[panelId] == nil {
            managedAgentResumeBindingsByPanelId[panelId] = stored
        }
        let effective: SurfaceResumeBindingSnapshot?
        if let stored, let detected {
            effective = stored.shouldYieldToDetectedSurfaceResumeBinding(detected) ? detected : stored
        } else if let detected {
            effective = detected
        } else if stored?.isProcessDetected == true {
            effective = nil
        } else {
            effective = stored
        }
        if let effective {
            surfaceResumeBindingsByPanelId[panelId] = effective
        } else {
            surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        }
        return effective
    }

    private func effectiveSessionRestorableAgent(
        panelId: UUID,
        observation: RestorableAgentSessionIndex.Entry?,
        resumeBinding: SurfaceResumeBindingSnapshot?,
        managedResumeBinding: SurfaceResumeBindingSnapshot?,
        terminal: TerminalPanel,
        transfer: Workspace.DetachedSurfaceTransfer?
    ) -> SessionRestorableAgentSnapshot? {
        if let observation {
            _ = restoredAgentLifecycle.reconcileCompletedAgent(
                panelId: panelId,
                observation: observation,
                currentProcessIdentity: Workspace.agentPIDProcessIdentity(pid:)
            )
        }
        let coordinated = restoredAgentLifecycle.continuationSnapshot(
            panelId: panelId,
            observation: observation,
            currentProcessIdentity: Workspace.agentPIDProcessIdentity(pid:)
        )
        let observed = restoredAgentLifecycle.resumeStatesByPanelId[panelId] == .completedAgentExit
            ? nil
            : observation?.snapshot
        let requiresCurrentManagedSession =
            invalidatedCachedTransferAgentSessionPanelIds.contains(panelId)
        let agentCompatibilityBinding = managedResumeBinding ?? resumeBinding
        let cachedTransferAgent: SessionRestorableAgentSnapshot? = {
            guard let candidate = transfer?.restorableAgent else { return nil }
            if let cachedBinding = transfer?.resumeBinding,
               cachedBinding.isAgentHookBinding {
                if let managedResumeBinding,
                   !cachedBinding.isSameManagedSession(as: managedResumeBinding) {
                    return nil
                }
            }
            return candidate
        }()
        let compatibleCandidate = [
            terminal.agentHibernationState?.agent,
            observed,
            coordinated,
            cachedTransferAgent,
        ].compactMap { candidate -> SessionRestorableAgentSnapshot? in
            if requiresCurrentManagedSession,
               managedResumeBinding?.hasCompleteManagedSessionIdentity != true {
                return nil
            }
            return Workspace.restorableAgentForSessionRestore(
                candidate,
                resumeBinding: agentCompatibilityBinding
            )
        }.first
        let compatible = restoredAgentLifecycle.reconcileSnapshotWithQueuedRestoreIntent(
            panelId: panelId,
            proposedSnapshot: compatibleCandidate
        )
        if let compatible {
            restoredAgentLifecycle.setSnapshot(compatible, panelId: panelId)
        }
        return compatible
    }

    private func sessionAgentWasRunning(
        restorableAgent: SessionRestorableAgentSnapshot?,
        resumeBinding: SurfaceResumeBindingSnapshot?,
        managedResumeBinding: SurfaceResumeBindingSnapshot?,
        terminal: TerminalPanel,
        transfer: Workspace.DetachedSurfaceTransfer?,
        observation: RestorableAgentSessionIndex.Entry?,
        currentAgentProcessIdentity: (Int) -> AgentPIDProcessIdentity?,
        agentProcessPresence: (Int) -> PIDPresence
    ) -> Bool? {
        let managedBinding = managedResumeBinding
            ?? resumeBinding.flatMap { $0.isAgentHookBinding ? $0 : nil }
        guard restorableAgent != nil || managedBinding != nil else { return nil }
        if restoredAgentLifecycle.hasQueuedRestoreIntent(
            panelId: terminal.id,
            matching: restorableAgent
        ) {
            return true
        }
        let expectedKind = managedBinding != nil
            ? managedBinding?.kind.flatMap {
                RestorableAgentKind(
                    persistedRawValue: $0,
                    registration: restorableAgent?.registration ?? observation?.snapshot.registration
                )
            }
            : restorableAgent?.kind
        let expectedSessionId = managedBinding != nil
            ? managedBinding?.checkpointId
            : restorableAgent?.sessionId
        let relevantObservation: RestorableAgentSessionIndex.Entry?
        if let expectedKind, let expectedSessionId {
            relevantObservation = observation?.matchingAgentSession(
                kind: expectedKind.rawValue,
                sessionId: expectedSessionId
            )
        } else {
            relevantObservation = nil
        }
        let confirmedRuntimeIdentities: Set<AgentPIDProcessIdentity> = {
            guard let expectedKind, expectedKind != .claude,
                  let expectedSessionId,
                  let runtime = agentRuntimeByPanelId[terminal.id] ?? transfer?.agentRuntime else {
                return []
            }
            let key = "\(expectedKind.rawValue).\(expectedSessionId)"
            guard let recordedIdentity = runtime.agentPIDProcessIdentities[key],
                  currentAgentProcessIdentity(Int(recordedIdentity.pid)) == recordedIdentity else {
                return []
            }
            return [recordedIdentity]
        }()
        if managedBinding != nil,
           relevantObservation == nil,
           confirmedRuntimeIdentities.isEmpty {
            return false
        }
        return (relevantObservation?.processLiveness ?? .unknown).wasRunning(
            fallingBackTo: terminal.shellActivity.state,
            recordedProcessIdentities: relevantObservation?.agentProcessIdentities ?? [:],
            confirmedRuntimeProcessIdentities: confirmedRuntimeIdentities,
            currentProcessIdentity: currentAgentProcessIdentity,
            processPresence: agentProcessPresence
        ) ?? false
    }
}
