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
        let layoutCodec = SessionSplitContainerLayoutCodec(controller: bonsplitController)
        let rawLayout = layoutCodec.snapshot(panelIdForTabId: { [self] in surfaceIdToPanelId[$0] })
        let orderedPanelIds = orderedSessionPanelIds()
        let panelSnapshots = orderedPanelIds
            .prefix(SessionPersistencePolicy.maxPanelsPerWorkspace)
            .compactMap { panelId in
                let transfer = detachedSurfaceTransfersByPanelId[panelId]
                let observationWorkspaceId = transfer?.sessionRestoreWorkspaceId ?? workspaceId
                return sessionPanelSnapshot(
                    panelId: panelId,
                    includeScrollback: includeScrollback,
                    observation: restorableAgentIndex?.entry(
                        workspaceId: observationWorkspaceId,
                        panelId: panelId
                    ),
                    detectedResumeBinding: surfaceResumeBindingIndex?.binding(
                        workspaceId: observationWorkspaceId,
                        panelId: panelId
                    ),
                    currentAgentProcessIdentity: currentAgentProcessIdentity,
                    agentProcessPresence: agentProcessPresence
                )
            }
        let persistedPanelIds = Set(panelSnapshots.map(\.id))
        let sourceWorkspaceIdsByPanelId = Dictionary(uniqueKeysWithValues: panelSnapshots.compactMap {
            panel -> (UUID, UUID)? in
            guard let transfer = detachedSurfaceTransfersByPanelId[panel.id] else { return nil }
            return (panel.id, transfer.sessionRestoreWorkspaceId)
        })
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
        currentAgentProcessIdentity: (Int) -> AgentPIDProcessIdentity?,
        agentProcessPresence: (Int) -> PIDPresence
    ) -> SessionPanelSnapshot? {
        guard let panel = panels[panelId] else { return nil }
        let transfer = detachedSurfaceTransfersByPanelId[panelId]
        let tab = surfaceId(forPanelId: panelId).flatMap { bonsplitController.tab($0) }
        let tabTitle = tab?.title
        let customTitle = transfer?.customTitle ?? (tab?.hasCustomTitle == true ? tabTitle : nil)
        let directory = sessionWorkingDirectory(panel: panel, transfer: transfer)

        let terminalSnapshot: SessionTerminalPanelSnapshot?
        let browserSnapshot: SessionBrowserPanelSnapshot?
        switch panel.panelType {
        case .terminal:
            guard let terminal = panel as? TerminalPanel else { return nil }
            let resumeBinding = effectiveSessionResumeBinding(
                panelId: panelId,
                detected: detectedResumeBinding,
                transfer: transfer
            )
            let restorableAgent = effectiveSessionRestorableAgent(
                panelId: panelId,
                observation: observation,
                resumeBinding: resumeBinding,
                terminal: terminal,
                transfer: transfer
            )
            let hibernation = terminal.agentHibernationState.flatMap { state in
                Workspace.restorableAgentForSessionRestore(
                    state.agent,
                    resumeBinding: resumeBinding
                ) == nil ? nil : state
            }
            let agentWasRunning = sessionAgentWasRunning(
                restorableAgent: restorableAgent,
                resumeBinding: resumeBinding,
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
            terminalSnapshot = SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                fontSize: terminal.surface.sessionFontSizeOverrideBasePoints(),
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
                textBoxDraft: terminal.sessionTextBoxDraftSnapshot(),
                isRemoteTerminal: transfer?.isRemoteTerminal ?? false,
                remotePTYSessionID: transfer?.remotePTYSessionID,
                wasAgentRunning: agentWasRunning
            )
            browserSnapshot = nil
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
                omnibarVisible: browser.isOmnibarVisible,
                backHistoryURLStrings: history.backHistoryURLStrings,
                forwardHistoryURLStrings: history.forwardHistoryURLStrings,
                transparentBackground: browser.sessionSnapshotTransparentBackground,
                diffViewerToken: diffViewer?.token,
                diffViewerRequestPath: diffViewer?.requestPath
            )
        default:
            return nil
        }

        return SessionPanelSnapshot(
            id: panelId,
            stableSurfaceId: panel.stableSurfaceId,
            type: panel.panelType,
            title: tabTitle ?? panel.displayTitle,
            customTitle: customTitle,
            customTitleSource: transfer?.customTitleSource ?? (customTitle == nil ? nil : .user),
            directory: directory,
            directoryIsTrustedRemoteReport: transfer?.directoryIsTrustedRemoteReport,
            isPinned: false,
            isManuallyUnread: transfer?.manuallyUnread ?? false,
            listeningPorts: [],
            ttyName: transfer?.ttyName,
            terminal: terminalSnapshot,
            browser: browserSnapshot,
            markdown: nil,
            filePreview: nil,
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
        detected: SurfaceResumeBindingSnapshot?,
        transfer: Workspace.DetachedSurfaceTransfer?
    ) -> SurfaceResumeBindingSnapshot? {
        let stored = surfaceResumeBindingsByPanelId[panelId] ?? transfer?.resumeBinding
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
        let compatible = [
            terminal.agentHibernationState?.agent,
            observed,
            coordinated,
            transfer?.restorableAgent,
        ].compactMap { candidate in
            Workspace.restorableAgentForSessionRestore(
                candidate,
                resumeBinding: resumeBinding
            )
        }.first
        if let compatible {
            restoredAgentLifecycle.snapshotsByPanelId[panelId] = compatible
        }
        return compatible
    }

    private func sessionAgentWasRunning(
        restorableAgent: SessionRestorableAgentSnapshot?,
        resumeBinding: SurfaceResumeBindingSnapshot?,
        terminal: TerminalPanel,
        transfer: Workspace.DetachedSurfaceTransfer?,
        observation: RestorableAgentSessionIndex.Entry?,
        currentAgentProcessIdentity: (Int) -> AgentPIDProcessIdentity?,
        agentProcessPresence: (Int) -> PIDPresence
    ) -> Bool? {
        guard restorableAgent != nil || resumeBinding?.isAgentHookBinding == true else { return nil }
        let expectedKind = resumeBinding?.isAgentHookBinding == true
            ? resumeBinding?.kind.flatMap(RestorableAgentKind.init(rawValue:))
            : restorableAgent?.kind
        let expectedSessionId = resumeBinding?.isAgentHookBinding == true
            ? resumeBinding?.checkpointId
            : restorableAgent?.sessionId
        let relevantObservation = observation.flatMap { entry -> RestorableAgentSessionIndex.Entry? in
            guard entry.snapshot.kind == expectedKind, entry.snapshot.sessionId == expectedSessionId else {
                return nil
            }
            return entry
        }
        let confirmedRuntimeIdentities: Set<AgentPIDProcessIdentity> = {
            guard let expectedKind, expectedKind != .claude,
                  let expectedSessionId,
                  let runtime = transfer?.agentRuntime else { return [] }
            let key = "\(expectedKind.rawValue).\(expectedSessionId)"
            guard let recordedIdentity = runtime.agentPIDProcessIdentities[key],
                  currentAgentProcessIdentity(Int(recordedIdentity.pid)) == recordedIdentity else {
                return []
            }
            return [recordedIdentity]
        }()
        if resumeBinding?.isAgentHookBinding == true,
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
