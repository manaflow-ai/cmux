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

    private var crashRecoveryStoredVerification: (facts: ResumeBindingFacts, presence: ClaudeTranscriptPresence)? {
        guard let panelId = focusedPanelId else { return nil }
        return restoredAgentVerificationByPanelId[panelId]
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
        if let trimmed = crashRecoveryResumeBinding?.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }
        let command = crashRecoveryResumeBinding?.command.trimmingCharacters(in: .whitespacesAndNewlines)
        return (command?.isEmpty == false) ? command : nil
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

    var resumeCwd: String? {
        crashRecoveryRestoredAgent?.workingDirectory
            ?? crashRecoveryResumeBinding?.cwd
            ?? currentDirectory
    }

    var resumeTranscriptPath: String? {
        crashRecoveryStoredVerification?.presence.resolvedPathAtWindowCwd
    }

    var resumeCommandConstructable: Bool {
        if let agent = crashRecoveryRestoredAgent {
            return agent.resumeCommand != nil
        }
        if let binding = crashRecoveryResumeBinding {
            return !binding.isProcessDetected
                && !binding.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    var transcriptExistsAtWindowCwd: Bool {
        crashRecoveryStoredVerification?.facts.transcriptExistsAtWindowCwd ?? false
    }

    var transcriptExistsElsewhere: Bool {
        crashRecoveryStoredVerification?.facts.transcriptExistsElsewhere ?? false
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

    nonisolated static func crashRecoveryVerification(
        agent: SessionRestorableAgentSnapshot,
        fileManager: FileManager = .default,
        homeDirectory: String = NSHomeDirectory()
    ) -> (facts: ResumeBindingFacts, presence: ClaudeTranscriptPresence) {
        let presence = transcriptPresence(
            kind: agent.kind,
            sessionId: agent.sessionId,
            cwd: agent.workingDirectory,
            configDirOverride: agent.launchCommand?.environment?["CLAUDE_CONFIG_DIR"],
            fileManager: fileManager,
            homeDirectory: homeDirectory
        )
        let facts = ResumeBindingFacts(
            hasBinding: true,
            agentKind: agent.kind,
            sessionId: agent.sessionId,
            resumeCommandConstructable: agent.resumeCommand != nil,
            transcriptExistsAtWindowCwd: presence.existsAtWindowCwd,
            transcriptExistsElsewhere: presence.existsElsewhere
        )
        return (facts, presence)
    }

    nonisolated static func crashRecoveryVerification(
        binding: SurfaceResumeBindingSnapshot,
        fileManager: FileManager = .default,
        homeDirectory: String = NSHomeDirectory()
    ) -> (facts: ResumeBindingFacts, presence: ClaudeTranscriptPresence) {
        let kind = binding.kind.flatMap(RestorableAgentKind.init(rawValue:))
        let sessionId = binding.checkpointId ?? WorkspaceResumeCoordinator.bareSessionId(from: binding.command)
        let presence: ClaudeTranscriptPresence
        if let kind {
            presence = transcriptPresence(
                kind: kind,
                sessionId: sessionId,
                cwd: binding.cwd,
                configDirOverride: binding.environment?["CLAUDE_CONFIG_DIR"],
                fileManager: fileManager,
                homeDirectory: homeDirectory
            )
        } else {
            presence = .absent
        }
        let facts = ResumeBindingFacts(
            hasBinding: !binding.isProcessDetected && (kind != nil || nonEmpty(sessionId) != nil),
            agentKind: kind,
            sessionId: sessionId,
            resumeCommandConstructable: !binding.isProcessDetected
                && !binding.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            transcriptExistsAtWindowCwd: presence.existsAtWindowCwd,
            transcriptExistsElsewhere: presence.existsElsewhere
        )
        return (facts, presence)
    }

    nonisolated private static func transcriptPresence(
        kind: RestorableAgentKind,
        sessionId: String?,
        cwd: String?,
        configDirOverride: String?,
        fileManager: FileManager,
        homeDirectory: String
    ) -> ClaudeTranscriptPresence {
        if kind == .claude {
            return ClaudeTranscriptPresenceResolver.resolve(
                sessionId: sessionId,
                cwd: cwd,
                configDirOverride: configDirOverride,
                fileManager: fileManager,
                homeDirectory: homeDirectory
            )
        }
        return ClaudeTranscriptPresence(
            existsAtWindowCwd: nonEmpty(sessionId) != nil,
            existsElsewhere: false,
            resolvedPathAtWindowCwd: nil
        )
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    @MainActor
    func prepareCrashRecoveryResumeVerification() async -> Bool {
        guard let panelId = focusedPanelId else { return false }
        if let agent = crashRecoveryRestoredAgent {
            let verification = await Task.detached(priority: .utility) {
                Self.crashRecoveryVerification(agent: agent)
            }.value
            guard restoredAgentSnapshotsByPanelId[panelId]?.kind == agent.kind,
                  restoredAgentSnapshotsByPanelId[panelId]?.sessionId == agent.sessionId else {
                return false
            }
            restoredAgentVerificationByPanelId[panelId] = verification
            return ResumeFidelityGate().isVerified(verification.facts)
        }
        if let binding = crashRecoveryResumeBinding {
            let verification = await Task.detached(priority: .utility) {
                Self.crashRecoveryVerification(binding: binding)
            }.value
            guard surfaceResumeBindingsByPanelId[panelId] == binding else { return false }
            restoredAgentVerificationByPanelId[panelId] = verification
            return ResumeFidelityGate().isVerified(verification.facts)
        }
        return false
    }

    @MainActor
    func crashRecoveryVerifiedResumeAction(defaults: UserDefaults = .standard) async -> RecoveryAction? {
        guard await prepareCrashRecoveryResumeVerification() else { return nil }
        let coordinator = WorkspaceResumeCoordinator(
            injectBreadcrumb: CrashRecoverySettings.injectResumeBreadcrumb(defaults: defaults)
        )
        let action = coordinator.router.route(
            coordinator.bindingFacts(for: self),
            context: coordinator.recoveryContext(for: self)
        )
        if case .resumeVerified = action {
            return action
        }
        return nil
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
    /// gated on a real crash, the opt-in breadcrumb setting, and the absence of
    /// a launch-level crash offer taking ownership of the injected prompt.
    ///
    /// Per-panel by construction (facts built from the panel's own snapshot, not
    /// the focused-panel accessors), so a multi-window restore recovers each
    /// window's own work without cross-bleed.
    @MainActor
    func scheduleCrashRecoveryReentry(
        panel: TerminalPanel,
        agent: SessionRestorableAgentSnapshot,
        defaults: UserDefaults = .standard,
        launchState: CrashRecoveryLaunchState?
    ) {
        guard let launchState else { return }
        guard CrashRecoverySettings.shouldDeliverSilentReentry(
            launchState: launchState,
            defaults: defaults
        ) else { return }
        guard ResumeBreadcrumbBuilder.isSupported(agent.kind) else { return }

        let panelId = panel.id
        let workspaceName = title
        let agentKind = agent.kind
        let sessionId = agent.sessionId
        let cwd = agent.workingDirectory

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let verification = Self.crashRecoveryVerification(agent: agent)
                let context = RecoveryContext(
                    workspaceName: workspaceName,
                    cwd: cwd,
                    transcriptPath: verification.presence.resolvedPathAtWindowCwd
                )

                let message: String?
                switch RecoveryRouter(injectBreadcrumb: true).route(verification.facts, context: context) {
                case .resumeVerified(let breadcrumb):
                    message = breadcrumb
                case .honestRecovery(let prompt, _):
                    message = prompt
                }
                return (verification: verification, message: message)
            }.value
            guard result.verification.facts.agentKind == agentKind,
                  result.verification.facts.sessionId == sessionId,
                  let message = result.message,
                  let self,
                  let panel = self.panels[panelId] as? TerminalPanel else { return }
            if self.restoredAgentSnapshotsByPanelId[panelId]?.kind == agentKind,
               self.restoredAgentSnapshotsByPanelId[panelId]?.sessionId == sessionId {
                self.restoredAgentVerificationByPanelId[panelId] = result.verification
            }
            self.sendInputWhenReady(message + "\n", to: panel)
        }
    }
}
