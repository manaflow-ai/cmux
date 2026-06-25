import Foundation

nonisolated struct CrashRecoveryVerification: Equatable, Sendable {
    var facts: ResumeBindingFacts
    var presence: ClaudeTranscriptPresence
    var fingerprint: CrashRecoveryVerificationFingerprint

    var needsFullRecoveryVerification: Bool {
        (facts.agentKind == .claude || facts.agentKind == .codex)
            && facts.hasBinding
            && !facts.transcriptExistsAtWindowCwd
            && !presence.searchedElsewhere
    }
}

nonisolated struct CrashRecoveryVerificationFingerprint: Equatable, Sendable {
    var kind: RestorableAgentKind?
    var sessionId: String?
    var cwd: String?
    var claudeConfigDir: String?
    var codexHome: String?
}

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

    private var crashRecoveryStoredVerification: CrashRecoveryVerification? {
        guard let panelId = focusedPanelId else { return nil }
        if let verification = restoredAgentVerificationByPanelId[panelId] {
            if let agent = crashRecoveryRestoredAgent {
                guard verification.fingerprint == Self.crashRecoveryVerificationFingerprint(agent: agent) else {
                    return Self.crashRecoveryVerificationWithoutFilesystemScan(agent: agent)
                }
                return verification
            }
            if let binding = crashRecoveryResumeBinding {
                guard verification.fingerprint == Self.crashRecoveryVerificationFingerprint(binding: binding) else {
                    return Self.crashRecoveryVerificationWithoutFilesystemScan(binding: binding)
                }
                return verification
            }
            return nil
        }
        if let agent = crashRecoveryRestoredAgent {
            return Self.crashRecoveryVerificationWithoutFilesystemScan(agent: agent)
        }
        if let binding = crashRecoveryResumeBinding {
            return Self.crashRecoveryVerificationWithoutFilesystemScan(binding: binding)
        }
        return nil
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
            return crashRecoveryResumeBinding?.isProcessDetected == true
                && focusedTerminalPanel?.surface.surface != nil
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

    var canDeliverHonestRecoveryPrompt: Bool {
        guard let panelId = focusedPanelId else { return false }
        return canDeliverHonestRecoveryPrompt(panelId: panelId)
    }

    func runNativeResume() {
        guard let panel = focusedTerminalPanel else { return }
        let startupInput = crashRecoveryRestoredAgent?.resumeStartupInput(allowOversizedInlineInput: true)
            ?? crashRecoveryResumeBinding?.inlineStartupInput(repairPortableAgentExecutable: false)
        guard let input = startupInput,
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if crashRecoveryRestoredAgent != nil || crashRecoveryResumeBinding != nil {
            restoredAgentResumeStatesByPanelId[panel.id] = .awaitingAutoResumeCommand
            invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panel.id)
        }
        sendInputWhenReady(input, to: panel, reason: .recoveryInput)
    }

    func deliverResumeBreadcrumb(_ text: String) {
        guard let panel = focusedTerminalPanel else { return }
        deliverResumeBreadcrumb(text, panelId: panel.id)
    }

    private func deliverResumeBreadcrumb(_ text: String, panelId: UUID) {
        guard let panel = panels[panelId] as? TerminalPanel else { return }
        if canDeliverResumeBreadcrumbNow(panelId: panelId) {
            sendInputWhenReady(text + "\n", to: panel, reason: .recoveryInput)
        } else if restoredAgentResumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand {
            pendingResumeBreadcrumbsByPanelId[panelId] = text
        }
    }

    func deliverHonestRecoveryPrompt(_ text: String) {
        guard let panel = focusedTerminalPanel else { return }
        sendInputWhenReady(text + "\n", to: panel, reason: .recoveryInput)
    }

    func deliverPendingResumeBreadcrumbIfReady(panelId: UUID) {
        guard canDeliverResumeBreadcrumbNow(panelId: panelId),
              let text = pendingResumeBreadcrumbsByPanelId.removeValue(forKey: panelId),
              let panel = panels[panelId] as? TerminalPanel else {
            return
        }
        sendInputWhenReady(text + "\n", to: panel, reason: .recoveryInput)
    }

    nonisolated static func crashRecoveryVerification(
        agent: SessionRestorableAgentSnapshot,
        searchElsewhere: Bool = true,
        fileManager: FileManager = .default,
        homeDirectory: String = NSHomeDirectory()
    ) -> CrashRecoveryVerification {
        let presence = transcriptPresence(
            kind: agent.kind,
            sessionId: agent.sessionId,
            cwd: agent.workingDirectory,
            configDirOverride: agent.launchCommand?.environment?["CLAUDE_CONFIG_DIR"],
            codexHomeOverride: agent.launchCommand?.environment?["CODEX_HOME"],
            searchElsewhere: searchElsewhere,
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
        return CrashRecoveryVerification(
            facts: facts,
            presence: presence,
            fingerprint: crashRecoveryVerificationFingerprint(agent: agent)
        )
    }

    nonisolated static func crashRecoveryVerification(
        binding: SurfaceResumeBindingSnapshot,
        searchElsewhere: Bool = true,
        fileManager: FileManager = .default,
        homeDirectory: String = NSHomeDirectory()
    ) -> CrashRecoveryVerification {
        let kind = binding.kind.flatMap(RestorableAgentKind.init(rawValue:))
        let sessionId = binding.checkpointId ?? WorkspaceResumeCoordinator.bareSessionId(from: binding.command)
        let presence: ClaudeTranscriptPresence
        if let kind {
            presence = transcriptPresence(
                kind: kind,
                sessionId: sessionId,
                cwd: binding.cwd,
                configDirOverride: binding.environment?["CLAUDE_CONFIG_DIR"],
                codexHomeOverride: binding.environment?["CODEX_HOME"],
                searchElsewhere: searchElsewhere,
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
        return CrashRecoveryVerification(
            facts: facts,
            presence: presence,
            fingerprint: crashRecoveryVerificationFingerprint(binding: binding)
        )
    }

    nonisolated static func crashRecoveryVerificationFingerprint(
        agent: SessionRestorableAgentSnapshot
    ) -> CrashRecoveryVerificationFingerprint {
        CrashRecoveryVerificationFingerprint(
            kind: agent.kind,
            sessionId: nonEmpty(agent.sessionId),
            cwd: nonEmpty(agent.workingDirectory),
            claudeConfigDir: nonEmpty(agent.launchCommand?.environment?["CLAUDE_CONFIG_DIR"]),
            codexHome: nonEmpty(agent.launchCommand?.environment?["CODEX_HOME"])
        )
    }

    nonisolated static func crashRecoveryVerificationFingerprint(
        binding: SurfaceResumeBindingSnapshot
    ) -> CrashRecoveryVerificationFingerprint {
        CrashRecoveryVerificationFingerprint(
            kind: binding.kind.flatMap(RestorableAgentKind.init(rawValue:)),
            sessionId: nonEmpty(binding.checkpointId ?? WorkspaceResumeCoordinator.bareSessionId(from: binding.command)),
            cwd: nonEmpty(binding.cwd),
            claudeConfigDir: nonEmpty(binding.environment?["CLAUDE_CONFIG_DIR"]),
            codexHome: nonEmpty(binding.environment?["CODEX_HOME"])
        )
    }

    nonisolated static func crashRecoveryVerificationWithoutFilesystemScan(
        agent: SessionRestorableAgentSnapshot,
        fileManager: FileManager = .default,
        homeDirectory: String = NSHomeDirectory()
    ) -> CrashRecoveryVerification? {
        guard agent.kind != .claude, agent.kind != .codex else { return nil }
        return crashRecoveryVerification(agent: agent, fileManager: fileManager, homeDirectory: homeDirectory)
    }

    nonisolated static func crashRecoveryVerificationWithoutFilesystemScan(
        binding: SurfaceResumeBindingSnapshot,
        fileManager: FileManager = .default,
        homeDirectory: String = NSHomeDirectory()
    ) -> CrashRecoveryVerification? {
        let kind = binding.kind.flatMap(RestorableAgentKind.init(rawValue:))
        guard kind != .claude, kind != .codex else { return nil }
        return crashRecoveryVerification(binding: binding, fileManager: fileManager, homeDirectory: homeDirectory)
    }

    nonisolated private static func transcriptPresence(
        kind: RestorableAgentKind,
        sessionId: String?,
        cwd: String?,
        configDirOverride: String?,
        codexHomeOverride: String?,
        searchElsewhere: Bool,
        fileManager: FileManager,
        homeDirectory: String
    ) -> ClaudeTranscriptPresence {
        switch kind {
        case .claude:
            return ClaudeTranscriptPresenceResolver.resolve(
                sessionId: sessionId,
                cwd: cwd,
                configDirOverride: configDirOverride,
                searchElsewhere: searchElsewhere,
                fileManager: fileManager,
                homeDirectory: homeDirectory
            )
        case .codex:
            return CodexTranscriptPresenceResolver.resolve(
                sessionId: sessionId,
                cwd: cwd,
                codexHomeOverride: codexHomeOverride,
                searchElsewhere: searchElsewhere,
                fileManager: fileManager,
                homeDirectory: homeDirectory
            )
        default:
            return .absent
        }
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    @MainActor
    func prepareCrashRecoveryResumeVerification() async -> Bool {
        guard await prepareCrashRecoveryRecoveryVerification() else { return false }
        let coordinator = WorkspaceResumeCoordinator(injectBreadcrumb: false)
        return ResumeFidelityGate().isVerified(coordinator.bindingFacts(for: self))
    }

    @MainActor
    func prepareCrashRecoveryRecoveryVerification() async -> Bool {
        guard let panelId = focusedPanelId else { return false }
        if let verification = crashRecoveryStoredVerification,
           !verification.needsFullRecoveryVerification {
            return verification.facts.hasBinding
        }
        if let agent = crashRecoveryRestoredAgent {
            let fingerprint = Self.crashRecoveryVerificationFingerprint(agent: agent)
            let verification = await Task.detached(priority: .utility) {
                Self.crashRecoveryVerification(agent: agent)
            }.value
            guard let currentAgent = restoredAgentSnapshotsByPanelId[panelId],
                  Self.crashRecoveryVerificationFingerprint(agent: currentAgent) == fingerprint else {
                return false
            }
            restoredAgentVerificationByPanelId[panelId] = verification
            return true
        }
        if let binding = crashRecoveryResumeBinding {
            let verification = await Task.detached(priority: .utility) {
                Self.crashRecoveryVerification(binding: binding)
            }.value
            guard surfaceResumeBindingsByPanelId[panelId] == binding else { return false }
            restoredAgentVerificationByPanelId[panelId] = verification
            return true
        }
        return false
    }

    @MainActor
    func crashRecoveryVerifiedResumeAction(defaults: UserDefaults = .standard) async -> RecoveryAction? {
        guard let action = await crashRecoveryRecoveryAction(defaults: defaults) else { return nil }
        if case .resumeVerified = action {
            return action
        }
        return nil
    }

    @MainActor
    func crashRecoveryRecoveryAction(defaults: UserDefaults = .standard) async -> RecoveryAction? {
        guard await prepareCrashRecoveryRecoveryVerification() else { return nil }
        let coordinator = WorkspaceResumeCoordinator(
            injectBreadcrumb: CrashRecoverySettings.injectResumeBreadcrumb(defaults: defaults)
        )
        let action = coordinator.router.route(
            coordinator.bindingFacts(for: self),
            context: coordinator.recoveryContext(for: self)
        )
        return action
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

    func scheduleRestoredAgentVerificationRefresh(
        workspaceSnapshot: SessionWorkspaceSnapshot,
        panelSnapshotsById: [UUID: SessionPanelSnapshot],
        oldToNewPanelIds: [UUID: UUID]
    ) {
        let agentJobs = restoredAgentSnapshotsByPanelId
            .map { (panelId: $0.key, agent: $0.value) }
            .sorted { $0.panelId.uuidString < $1.panelId.uuidString }
        let bindingJobs = surfaceResumeBindingsByPanelId
            .compactMap { item -> (panelId: UUID, binding: SurfaceResumeBindingSnapshot)? in
                guard restoredAgentSnapshotsByPanelId[item.key] == nil,
                      item.value.isAgentHookBinding else {
                    return nil
                }
                return (item.key, item.value)
            }
            .sorted { $0.panelId.uuidString < $1.panelId.uuidString }
        guard !agentJobs.isEmpty || !bindingJobs.isEmpty else { return }

        let workspaceAutoTitle = workspaceSnapshot.customTitleSource == .auto
            ? (
                title: workspaceSnapshot.customTitle,
                source: workspaceSnapshot.customTitleSource,
                focusedPanelId: workspaceSnapshot.focusedPanelId.flatMap { oldToNewPanelIds[$0] },
                focusedPanelSnapshot: workspaceSnapshot.focusedPanelId.flatMap { panelSnapshotsById[$0] }
            )
            : nil
        let panelAutoTitles = oldToNewPanelIds.compactMap { oldPanelId, newPanelId -> (panelId: UUID, snapshot: SessionPanelSnapshot)? in
            guard let snapshot = panelSnapshotsById[oldPanelId],
                  snapshot.customTitleSource == .auto else {
                return nil
            }
            return (newPanelId, snapshot)
        }

        restoredAgentVerificationTask?.cancel()
        restoredAgentVerificationTask = Task.detached(priority: .utility) {
            var agentResults: [(panelId: UUID, agent: SessionRestorableAgentSnapshot, verification: CrashRecoveryVerification)] = []
            var bindingResults: [(panelId: UUID, binding: SurfaceResumeBindingSnapshot, verification: CrashRecoveryVerification)] = []
            var cache: [String: CrashRecoveryVerification] = [:]

            func cachedVerification(
                key: String,
                compute: () -> CrashRecoveryVerification
            ) -> CrashRecoveryVerification {
                if let cached = cache[key] { return cached }
                let verification = compute()
                cache[key] = verification
                return verification
            }

            for job in agentJobs {
                guard !Task.isCancelled else { return }
                let configDir = job.agent.launchCommand?.environment?["CLAUDE_CONFIG_DIR"] ?? ""
                let codexHome = job.agent.launchCommand?.environment?["CODEX_HOME"] ?? ""
                let key = "agent|\(job.agent.kind.rawValue)|\(job.agent.sessionId)|\(job.agent.workingDirectory ?? "")|\(configDir)|\(codexHome)"
                let verification = cachedVerification(key: key) {
                    Workspace.crashRecoveryVerification(agent: job.agent, searchElsewhere: false)
                }
                agentResults.append((job.panelId, job.agent, verification))
            }

            for job in bindingJobs {
                guard !Task.isCancelled else { return }
                let key = [
                    "binding",
                    job.binding.kind ?? "",
                    job.binding.checkpointId ?? "",
                    job.binding.command,
                    job.binding.cwd ?? "",
                    job.binding.environment?["CLAUDE_CONFIG_DIR"] ?? "",
                    job.binding.environment?["CODEX_HOME"] ?? "",
                ].joined(separator: "|")
                let verification = cachedVerification(key: key) {
                    Workspace.crashRecoveryVerification(binding: job.binding, searchElsewhere: false)
                }
                bindingResults.append((job.panelId, job.binding, verification))
            }

            guard !Task.isCancelled else { return }
            let resolvedAgentResults = agentResults
            let resolvedBindingResults = bindingResults
            await MainActor.run { [weak self] in
                guard let self else { return }
                for result in resolvedAgentResults {
                    guard let currentAgent = self.restoredAgentSnapshotsByPanelId[result.panelId],
                          Self.crashRecoveryVerificationFingerprint(agent: currentAgent) == result.verification.fingerprint else {
                        continue
                    }
                    self.restoredAgentVerificationByPanelId[result.panelId] = result.verification
                }
                for result in resolvedBindingResults {
                    guard self.surfaceResumeBindingsByPanelId[result.panelId] == result.binding else {
                        continue
                    }
                    self.restoredAgentVerificationByPanelId[result.panelId] = result.verification
                }

                if let workspaceAutoTitle,
                   let focusedPanelId = workspaceAutoTitle.focusedPanelId,
                   let focusedPanelSnapshot = workspaceAutoTitle.focusedPanelSnapshot,
                   self.effectiveCustomTitleSource != .user,
                   let verification = self.restoredAgentVerificationByPanelId[focusedPanelId],
                   Self.restoredPanelNameIsVerified(
                       focusedPanelSnapshot,
                       cachedVerification: verification
                   ) {
                    let restoredName = Self.restoredName(
                        persistedTitle: workspaceAutoTitle.title,
                        source: workspaceAutoTitle.source,
                        isVerified: true
                    )
                    self.applyRestoredWorkspaceName(restoredName)
                }
                for item in panelAutoTitles {
                    guard self.panelCustomTitleSources[item.panelId] != .user,
                          let verification = self.restoredAgentVerificationByPanelId[item.panelId],
                          Self.restoredPanelNameIsVerified(
                              item.snapshot,
                              cachedVerification: verification
                          ) else {
                        continue
                    }
                    self.applyRestoredPanelName(from: item.snapshot, toPanelId: item.panelId)
                }
                self.restoredAgentVerificationTask = nil
            }
        }
    }

    /// Silent-path agent-first re-entry for a cold-restored agent panel (U11/R17).
    /// Per-panel by construction: facts come from the panel's own snapshot.
    @MainActor
    func scheduleCrashRecoveryReentry(
        panel: TerminalPanel,
        agent: SessionRestorableAgentSnapshot,
        nativeResumeAlreadyScheduled: Bool,
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

        cancelCrashRecoveryReentryTask(panelId: panelId)
        let taskToken = UUID()
        crashRecoveryReentryTaskTokensByPanelId[panelId] = taskToken
        crashRecoveryReentryTasksByPanelId[panelId] = Task { @MainActor [weak self] in
            defer {
                if let self,
                   self.crashRecoveryReentryTaskTokensByPanelId[panelId] == taskToken {
                    self.crashRecoveryReentryTasksByPanelId.removeValue(forKey: panelId)
                    self.crashRecoveryReentryTaskTokensByPanelId.removeValue(forKey: panelId)
                }
            }
            let result = await Task.detached(priority: .utility) {
                let verification = Self.crashRecoveryVerification(agent: agent)
                let context = RecoveryContext(
                    workspaceName: workspaceName,
                    cwd: cwd,
                    transcriptPath: verification.presence.resolvedPathAtWindowCwd
                )
                let action = RecoveryRouter(injectBreadcrumb: true).route(verification.facts, context: context)
                return (verification: verification, action: action)
            }.value
            guard !Task.isCancelled else { return }
            guard result.verification.facts.agentKind == agentKind,
                  result.verification.facts.sessionId == sessionId,
                  let self,
                  let panel = self.panels[panelId] as? TerminalPanel else { return }
            if self.restoredAgentSnapshotsByPanelId[panelId]?.kind == agentKind,
               self.restoredAgentSnapshotsByPanelId[panelId]?.sessionId == sessionId {
                self.restoredAgentVerificationByPanelId[panelId] = result.verification
            }
            switch result.action {
            case .resumeVerified(let breadcrumb):
                if !nativeResumeAlreadyScheduled,
                   let input = agent.resumeStartupInput(allowOversizedInlineInput: true),
                   !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.restoredAgentResumeStatesByPanelId[panelId] = .awaitingAutoResumeCommand
                    self.sendInputWhenReady(input, to: panel, reason: .recoveryInput)
                }
                if let breadcrumb {
                    self.deliverResumeBreadcrumb(breadcrumb, panelId: panelId)
                }
            case .honestRecovery(let prompt, _):
                guard self.canDeliverHonestRecoveryPrompt(panelId: panelId) else { return }
                self.sendInputWhenReady(prompt + "\n", to: panel, reason: .recoveryInput)
            }
        }
    }

    private func canDeliverHonestRecoveryPrompt(panelId: UUID) -> Bool {
        switch restoredAgentResumeStatesByPanelId[panelId] {
        case .some(.awaitingAutoResumeCommand),
             .some(.autoResumeCommandRunning),
             .some(.observedAgentCommandRunning):
            return true
        case .some(.manualResumeAvailable), nil:
            return false
        }
    }

    private func canDeliverResumeBreadcrumbNow(panelId: UUID) -> Bool {
        switch restoredAgentResumeStatesByPanelId[panelId] {
        case .some(.autoResumeCommandRunning), .some(.observedAgentCommandRunning):
            return true
        case .some(.awaitingAutoResumeCommand), .some(.manualResumeAvailable):
            return false
        case nil:
            return isAgentLive
        }
    }
}
