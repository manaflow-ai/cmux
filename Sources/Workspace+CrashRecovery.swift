import Foundation

// MARK: - Crash recovery: resumable surface conformance

/// Bridges the live workspace into the crash-recovery resume coordinator. The
/// "surface" is the workspace's focused terminal panel.
extension Workspace: ResumableWorkspaceSurface {
    private var crashRecoveryResumeBinding: SurfaceResumeBindingSnapshot? {
        guard let panelId = focusedPanelId else { return nil }
        return surfaceResumeBinding(panelId: panelId)
    }

    /// A cold-restored agent (after a crash/relaunch) lives here, not in the
    /// live-detected `surfaceResumeBinding`. This is the primary resumability
    /// source for the crash-recovery flow; it is populated synchronously during
    /// restore (no async reconciliation race).
    private var crashRecoveryRestoredAgent: SessionRestorableAgentSnapshot? {
        guard let panelId = focusedPanelId else { return nil }
        return restoredAgentSnapshotsByPanelId[panelId]
    }

    private var crashRecoveryResumeState: RestoredAgentResumeState? {
        guard let panelId = focusedPanelId else { return nil }
        return restoredAgentResumeStatesByPanelId[panelId]
    }

    var resumeWorkspaceName: String { title }

    var resumeAgentKind: RestorableAgentKind? {
        if let agent = crashRecoveryRestoredAgent { return agent.kind }
        guard let kind = crashRecoveryResumeBinding?.kind else { return nil }
        return RestorableAgentKind(rawValue: kind)
    }

    var resumeSessionToken: String? {
        if let agent = crashRecoveryRestoredAgent, !agent.sessionId.isEmpty {
            return agent.sessionId
        }
        let trimmed = crashRecoveryResumeBinding?.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    var isResumeBindingProven: Bool {
        // A cold-restored agent snapshot came from the session index, so it is
        // proven by cmux-owned restore state.
        if crashRecoveryRestoredAgent != nil { return true }
        guard let binding = crashRecoveryResumeBinding else { return false }
        return !binding.isProcessDetected
    }

    var isAgentLive: Bool {
        switch crashRecoveryResumeState {
        case .observedAgentCommandRunning, .autoResumeCommandRunning:
            return true
        case .manualResumeAvailable, .awaitingAutoResumeCommand:
            return false
        case nil:
            return crashRecoveryResumeBinding != nil && focusedTerminalPanel?.surface.surface != nil
        }
    }

    func runNativeResume() {
        guard let panel = focusedTerminalPanel else { return }
        let startupInput = crashRecoveryRestoredAgent?.resumeStartupInput(allowOversizedInlineInput: true)
            ?? crashRecoveryResumeBinding?.inlineStartupInput(repairPortableAgentExecutable: false)
        guard let input = startupInput,
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sendInputWhenReady(input, to: panel)
    }

    func deliverResumeBreadcrumb(_ text: String) {
        guard let panel = focusedTerminalPanel else { return }
        sendInputWhenReady(text + "\n", to: panel)
    }

    /// Resume the focused agent and, when enabled, inject the breadcrumb. The
    /// single shared entry used by the manual action (U6) and the crash offer (U5).
    @discardableResult
    func resumeWhereWeLeftOff(defaults: UserDefaults = .standard) -> ResumeOutcome {
        WorkspaceResumeCoordinator(
            injectBreadcrumb: CrashRecoverySettings.injectResumeBreadcrumb(defaults: defaults)
        ).resume(self)
    }

    /// Whether the focused surface can be resumed (used to enable the menu/command).
    func canResumeWhereWeLeftOff(defaults: UserDefaults = .standard) -> Bool {
        WorkspaceResumeCoordinator(
            injectBreadcrumb: CrashRecoverySettings.injectResumeBreadcrumb(defaults: defaults)
        ).canResume(self)
    }

    /// Silent-path agent-first re-entry for a cold-restored agent panel (U11/R17).
    ///
    /// cmux already issues the native `claude --resume` during restore (PR #6741
    /// fixes the cwd it `cd`s into). This layers the re-entry message on top,
    /// gated on a real crash / intentional-update relaunch and the opt-in
    /// breadcrumb setting.
    ///
    /// Per-panel by construction (facts built from the panel's own snapshot, not
    /// the focused-panel accessors), so a multi-window restore recovers each
    /// window's own work without cross-bleed.
    func scheduleCrashRecoveryReentry(
        panel: TerminalPanel,
        agent: SessionRestorableAgentSnapshot,
        defaults: UserDefaults = .standard,
        launchState: CrashRecoveryLaunchState?
    ) {
        guard CrashRecoverySettings.injectResumeBreadcrumb(defaults: defaults) else { return }
        guard let launchState else { return }
        guard launchState.priorRunCrashed || launchState.restoreWasIntended else { return }
        guard ResumeBreadcrumbBuilder.isSupported(agent.kind) else { return }

        let panelId = panel.id
        let workspaceName = title
        let agentKind = agent.kind
        let sessionId = agent.sessionId
        let cwd = agent.workingDirectory
        let configDirOverride = agent.launchCommand?.environment?["CLAUDE_CONFIG_DIR"]
        let resumeCommandConstructable = agent.resumeCommand != nil

        Task { [weak self] in
            let message = await Task.detached(priority: .utility) {
                let presence: ClaudeTranscriptPresence
                if agentKind == .claude {
                    presence = ClaudeTranscriptPresenceResolver.resolve(
                        sessionId: sessionId,
                        cwd: cwd,
                        configDirOverride: configDirOverride
                    )
                } else {
                    presence = ClaudeTranscriptPresence(
                        existsAtWindowCwd: !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        existsElsewhere: false,
                        resolvedPathAtWindowCwd: nil
                    )
                }

                let facts = ResumeBindingFacts(
                    hasBinding: true,
                    agentKind: agentKind,
                    sessionId: sessionId,
                    resumeCommandConstructable: resumeCommandConstructable,
                    transcriptExistsAtWindowCwd: presence.existsAtWindowCwd,
                    transcriptExistsElsewhere: presence.existsElsewhere
                )
                let context = RecoveryContext(
                    workspaceName: workspaceName,
                    cwd: cwd,
                    transcriptPath: presence.resolvedPathAtWindowCwd
                )

                switch RecoveryRouter(injectBreadcrumb: true).route(facts, context: context) {
                case .resumeVerified(let breadcrumb):
                    return breadcrumb
                case .honestRecovery(let prompt, _):
                    return prompt
                }
            }.value
            guard let message,
                  let self,
                  let panel = self.panels[panelId] as? TerminalPanel else { return }
            self.sendInputWhenReady(message + "\n", to: panel)
        }
    }
}
