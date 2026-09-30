import AppKit
import CmuxTerminal
import CmuxWorkspaces
import Foundation

extension AppDelegate {
    func sessionScrollbackCheckpointStore() -> SessionScrollbackCheckpointStore? {
        sessionSnapshotStore.defaultSnapshotFileURL().map {
            SessionScrollbackCheckpointStore(primarySnapshotURL: $0)
        }
    }

    /// Drops the previous launch's checkpoints unless it exited uncleanly; see
    /// `SessionScrollbackCheckpointStore.prepareForLaunch`.
    func prepareSessionScrollbackCheckpointsForLaunch(
        previousLaunchWasUnclean: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard !SessionRestorePolicy.isRunningUnderAutomatedTests(environment: environment) else { return }
        guard environment["CMUX_DISABLE_SESSION_RESTORE"] == "1" || !previousLaunchWasUnclean else { return }
        sessionScrollbackCheckpointStore()?.prepareForLaunch(previousLaunchWasUnclean: false)
    }

    func startSessionScrollbackCheckpointsIfNeeded(environment: [String: String]) {
        guard sessionScrollbackCheckpointCoordinator == nil,
              SessionScrollbackCheckpointPolicy.isEnabled(environment: environment),
              let store = sessionScrollbackCheckpointStore() else { return }
        let queue = sessionScrollbackCheckpointQueue
        let activity = GhosttyApp.terminalScrollbackCheckpointActivity
        sessionScrollbackCheckpointCoordinator = SessionScrollbackCheckpointCoordinator(
            environment: SessionScrollbackCheckpointCoordinator.Environment(
                uptime: { ProcessInfo.processInfo.systemUptime },
                wallClock: { Date().timeIntervalSince1970 },
                canCheckpoint: { [weak self] in
                    guard let self else { return false }
                    return !self.isTerminatingApp
                        && self.didAttemptStartupSessionRestore
                        && !self.isApplyingSessionRestore
                },
                secondsSinceTyping: { [weak self] in
                    guard let self, self.lastTypingActivityAt > 0 else { return nil }
                    return ProcessInfo.processInfo.systemUptime - self.lastTypingActivityAt
                },
                candidates: { [weak self] in
                    self?.sessionScrollbackCheckpointCandidates() ?? []
                },
                scheduleNextCapture: { work in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { work() }
                    }
                },
                persist: { batch in
                    // A removal means the panel stopped being eligible (for
                    // example a command started running). Delete its old file
                    // before returning, after earlier queued writes, so a crash
                    // before the async batch runs cannot leave stale scrollback
                    // for the next unclean restore to merge.
                    if !batch.removals.isEmpty {
                        let removals = SessionScrollbackCheckpointWriteBatch(
                            captures: [],
                            removals: batch.removals,
                            livePanelIds: nil
                        )
                        queue.sync {
                            _ = store.apply(removals)
                        }
                    }
                    let writes = SessionScrollbackCheckpointWriteBatch(
                        captures: batch.captures,
                        removals: [],
                        livePanelIds: batch.livePanelIds
                    )
                    queue.async {
                        store.applyMarkingFailuresPending(writes, activity: activity)
                    }
                }
            ),
            activity: activity
        )
    }

    /// Live terminals a scrollback checkpoint may capture: the same panels the
    /// session snapshot walks (registered windows, their docks, and windowless
    /// routes that still fit the persisted window budget).
    func sessionScrollbackCheckpointCandidates() -> [SessionScrollbackCheckpointCoordinator.Candidate] {
        var candidates: [SessionScrollbackCheckpointCoordinator.Candidate] = []
        var seen = Set<UUID>()
        let restorePolicy = Workspace.makeSessionRestorePolicyService()
        let restorableAgentIndex = SharedLiveAgentIndex.shared.index ?? .empty

        func append(
            panelId: UUID,
            terminal: TerminalPanel,
            shellActivityState: PanelShellActivityState?,
            resumeBinding: SurfaceResumeBindingSnapshot?,
            restorableAgent: SessionRestorableAgentSnapshot?,
            agentWasRunning: Bool?,
            autoResumeAgentSessions: Bool
        ) {
            guard seen.insert(panelId).inserted else { return }
            let localTmuxStartCommand = restorePolicy.localTmuxStartCommand(
                terminal.surface.debugTmuxStartCommand()
            )
            let restorableTmuxStartCommand = localTmuxStartCommand
                ?? (restorableAgent == nil
                    ? restorePolicy.restorableTmuxStartCommand(terminal.surface.debugTmuxStartCommand())
                    : nil)
            let resumeStartupInput = localTmuxStartCommand == nil
                ? restorePolicy.surfaceResumeStartupInput(
                    resumeBinding,
                    autoResumeAgentSessions: autoResumeAgentSessions && (agentWasRunning ?? true),
                    promptForApproval: false,
                    approvalStoreURL: SurfaceResumeApprovalStore.defaultURL()
                )
                : nil
            let closeConfirmationRequired = Workspace.resolveCloseConfirmation(
                shellActivityState: shellActivityState,
                fallbackNeedsConfirmClose: terminal.surface.snapshotNeedsConfirmClose()
            )
            let isEligible = restorePolicy
                .shouldPersistSessionScrollback(closeConfirmationRequired: closeConfirmationRequired)
                && restorePolicy.shouldReplaySessionScrollback(
                    hasRestorableAgent: restorableAgent != nil,
                    tmuxStartCommand: restorableTmuxStartCommand,
                    hasResumeStartupWork: resumeStartupInput != nil
                )
                && terminal.agentHibernationState == nil
            candidates.append(SessionScrollbackCheckpointCoordinator.Candidate(
                panelId: panelId,
                surfaceId: terminal.surface.id,
                isEligible: isEligible,
                beginCapture: { [weak terminal] in
                    guard let terminal else { return nil }
                    return TerminalScrollbackCheckpointExport.begin(
                        terminal: terminal,
                        lineLimit: SessionPersistencePolicy.maxScrollbackLinesPerTerminal
                    )
                }
            ))
        }
        func appendTerminals(from dock: DockSplitStore) {
            for (panelId, panel) in dock.panels {
                guard let terminal = panel as? TerminalPanel else { continue }
                let resumeBinding = dock.managedAgentResumeBindingsByPanelId[panelId]
                    ?? dock.surfaceResumeBindingsByPanelId[panelId]
                let restorableAgent = dock.restoredAgentLifecycle.resumeStatesByPanelId[panelId]
                    == .completedAgentExit
                    ? nil
                    : Workspace.restorableAgentForSessionRestore(
                        dock.restoredAgentLifecycle.snapshotsByPanelId[panelId]
                            ?? terminal.agentHibernationState?.agent,
                        resumeBinding: resumeBinding
                    )
                let transfer = dock.detachedSurfaceTransfersByPanelId[panelId]
                let observation = restorableAgentIndex.entryForStablePanel(
                    workspaceId: transfer?.sessionRestoreWorkspaceId ?? dock.workspaceId,
                    panelId: panelId,
                    revalidateProcessEvidence: false
                )
                let agentWasRunning = dock.sessionAgentWasRunning(
                    restorableAgent: restorableAgent,
                    resumeBinding: resumeBinding,
                    managedResumeBinding: dock.managedAgentResumeBindingsByPanelId[panelId],
                    terminal: terminal,
                    transfer: transfer,
                    observation: observation
                )
                append(
                    panelId: panelId,
                    terminal: terminal,
                    shellActivityState: terminal.shellActivity.state,
                    resumeBinding: resumeBinding,
                    restorableAgent: restorableAgent,
                    agentWasRunning: agentWasRunning,
                    autoResumeAgentSessions: AgentSessionAutoResumeSettings.isEnabled(
                        defaults: dock.agentSessionAutoResumeDefaults
                    )
                )
            }
        }
        func appendTerminals(from manager: TabManager) {
            for workspace in manager.tabs {
                let shellActivityStates = workspace.panelShellActivityStates
                for (panelId, panel) in workspace.panels {
                    guard let terminal = panel as? TerminalPanel else { continue }
                    let resumeBinding = workspace.surfaceResumeBindingsByPanelId[panelId]
                    let restorableAgent = workspace.restoredAgentResumeStatesByPanelId[panelId]
                        == .completedAgentExit
                        ? nil
                        : Workspace.restorableAgentForSessionRestore(
                            workspace.restoredAgentSnapshotsByPanelId[panelId]
                                ?? terminal.agentHibernationState?.agent,
                            resumeBinding: resumeBinding
                        )
                    let observation = restorableAgentIndex.entryForStablePanel(
                        workspaceId: workspace.id,
                        panelId: panelId,
                        revalidateProcessEvidence: false
                    )
                    let agentWasRunning = workspace.sessionAgentWasRunning(
                        panelId: panelId,
                        restorableAgent: restorableAgent,
                        resumeBinding: resumeBinding,
                        terminal: terminal,
                        observation: observation
                    )
                    append(
                        panelId: panelId,
                        terminal: terminal,
                        shellActivityState: shellActivityStates[panelId],
                        resumeBinding: resumeBinding,
                        restorableAgent: restorableAgent,
                        agentWasRunning: agentWasRunning,
                        autoResumeAgentSessions: AgentSessionAutoResumeSettings.isEnabled(
                            defaults: workspace.agentSessionAutoResumeDefaults
                        )
                    )
                }
                if let dock = workspace._dockSplit {
                    appendTerminals(from: dock)
                }
            }
        }

        for context in mainWindowContexts.values {
            appendTerminals(from: context.tabManager)
            if let dock = context.existingWindowDock() {
                appendTerminals(from: dock)
            }
        }
        for route in mainWindowLifecycleCoordinator.eligibleOrphanedRoutesForPersistence() {
            guard let manager = route.tabManager else { continue }
            appendTerminals(from: manager)
            if case .live(let dock)? = route.windowDock {
                appendTerminals(from: dock)
            }
        }
        return candidates
    }

    /// Restored scrollback held in memory for live terminal panels, keyed by
    /// their current (post-restore) panel ids.
    func sessionScrollbackCheckpointRestoredSeeds() -> [SessionScrollbackCheckpointCoordinator.Seed] {
        var seeds: [SessionScrollbackCheckpointCoordinator.Seed] = []
        var seen = Set<UUID>()
        func append(_ scrollbackByPanelId: [UUID: String], panels: [UUID: any Panel]) {
            for (panelId, scrollback) in scrollbackByPanelId {
                guard let terminal = panels[panelId] as? TerminalPanel,
                      seen.insert(panelId).inserted else { continue }
                seeds.append(.init(panelId: panelId, surfaceId: terminal.surface.id, scrollback: scrollback))
            }
        }
        func append(from dock: DockSplitStore) {
            append(dock.restoredTerminalScrollbackByPanelId, panels: dock.panels)
        }
        for context in mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                append(workspace.restoredTerminalScrollbackByPanelId, panels: workspace.panels)
                if let dock = workspace._dockSplit {
                    append(from: dock)
                }
            }
            if let dock = context.existingWindowDock() {
                append(from: dock)
            }
        }
        return seeds
    }
}

/// Splits the quit path's VT-export capture so only the Ghostty call runs on main.
enum TerminalScrollbackCheckpointExport {
    /// Main-thread half: Ghostty formats the terminal's scrollback into a temp
    /// file. Returns the off-main reader, or nil when the export failed.
    @MainActor
    static func begin(terminal: TerminalPanel, lineLimit: Int) -> SessionScrollbackCheckpointExport? {
        let exportedPath = GhosttyApp.terminalPasteboard.captureNextStandardClipboardWrite {
            terminal.performInternalBindingAction("write_screen_file:copy,vt")
        }
        guard let path = TerminalController.normalizedExportedScreenPath(exportedPath) else { return nil }
        let fileURL = URL(fileURLWithPath: path)
        return SessionScrollbackCheckpointExport(
            finish: { TerminalScrollbackCheckpointExport.read(fileURL: fileURL, lineLimit: lineLimit) },
            discard: { TerminalScrollbackCheckpointExport.remove(fileURL: fileURL) }
        )
    }

    nonisolated static func remove(fileURL: URL) {
        guard TerminalController.shouldRemoveExportedScreenFile(fileURL: fileURL) else { return }
        try? FileManager.default.removeItem(at: fileURL)
        if TerminalController.shouldRemoveExportedScreenDirectory(fileURL: fileURL) {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
    }

    /// Off-main half; mirrors `readTerminalTextFromVTExportForSnapshot` after the export.
    nonisolated static func read(fileURL: URL, lineLimit: Int) -> String? {
        defer { remove(fileURL: fileURL) }
        guard let data = try? Data(contentsOf: fileURL),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        return TerminalController.tailTerminalLines(
            TerminalController.normalizedMobileVTExportText(raw),
            maxLines: lineLimit
        )
    }
}
