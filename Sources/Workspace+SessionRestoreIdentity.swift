import AppKit
import CMUXAgentLaunch
import CmuxWorkspaces
import Foundation

extension Workspace {
    /// Re-adopts a persisted panel identity unless it is still live elsewhere.
    func adoptPersistedStableSurfaceId(from snapshot: SessionPanelSnapshot, panelId: UUID) {
        if let stableSurfaceId = snapshot.stableSurfaceId,
           sessionRestoreIdentityExclusions.shouldAdopt(stableSurfaceId),
           let panel = panels[panelId] {
            panel.adoptStableSurfaceId(stableSurfaceId)
        }
    }

    func restoreClosedPanel(
        _ entry: ClosedPanelHistoryEntry,
        excludingStableIdentities: Set<UUID>
    ) -> UUID? {
        sessionRestoreIdentityExclusions.beginRestore(excluding: excludingStableIdentities)
        defer { sessionRestoreIdentityExclusions.endRestore() }
        return restoreClosedPanel(entry)
    }

    /// Resolves a resume target by runtime panel id first, then restart-stable surface id.
    func terminalPanelIdForSurfaceResumeTarget(_ targetId: UUID) -> UUID? {
        if terminalPanel(for: targetId) != nil {
            return targetId
        }
        let matches = panels.values.compactMap { panel -> UUID? in
            guard panel.stableSurfaceId == targetId,
                  terminalPanel(for: panel.id) != nil else {
                return nil
            }
            return panel.id
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    func logSessionRestoreTerminalPanelBinding(
        snapshot: SessionPanelSnapshot,
        resumeBinding: SurfaceResumeBindingSnapshot?,
        approvedBinding: SurfaceResumeBindingSnapshot?,
        bindingLaunch: SurfaceResumeStartupLaunch?,
        agentLaunch: SurfaceResumeStartupLaunch?,
        startupCommand: String?,
        startupInput: String?
    ) {
        var fields = sessionRestoreLogFields(snapshot: snapshot)
        fields["binding"] = resumeBinding == nil ? "missing" : "found"
        fields["approved"] = approvedBinding == nil ? "0" : "1"
        fields["launch"] = sessionRestoreLaunchKind(bindingLaunch: bindingLaunch, agentLaunch: agentLaunch)
        fields["resumeCommandPlanned"] = sessionRestoreHasPlannedCommandLaunch(
            bindingLaunch: bindingLaunch,
            agentLaunch: agentLaunch
        ) ? "1" : "0"
        fields["startupPlan"] = sessionRestoreStartupKind(command: startupCommand, input: startupInput)
        if let resumeBinding {
            fields["bindingKind"] = resumeBinding.kind ?? ""
            fields["bindingSource"] = resumeBinding.source ?? ""
            fields["hasCheckpoint"] = resumeBinding.checkpointId == nil ? "0" : "1"
        }
        StartupBreadcrumbLog.appendBatched("app.init.sessionRestore.panel.binding", fields: fields)
    }

    func logSessionRestoreTerminalPanelOutcome(
        snapshot: SessionPanelSnapshot,
        restoredPanelId: UUID?,
        storedBinding: SurfaceResumeBindingSnapshot?,
        startupCommand: String?,
        startupInput: String?,
        outcome: String
    ) {
        var fields = sessionRestoreLogFields(snapshot: snapshot)
        fields["outcome"] = outcome
        fields["restoredPanelId"] = restoredPanelId?.uuidString ?? ""
        fields["storedBinding"] = storedBinding == nil ? "0" : "1"
        fields["startup"] = sessionRestoreStartupKind(command: startupCommand, input: startupInput)
        let didCreatePanel = restoredPanelId != nil
        fields["startupCommandIssued"] = didCreatePanel && startupCommand != nil ? "1" : "0"
        StartupBreadcrumbLog.appendBatched("app.init.sessionRestore.panel.outcome", fields: fields)
    }

    private func sessionRestoreLogFields(snapshot: SessionPanelSnapshot) -> [String: String] {
        [
            "workspaceId": id.uuidString,
            "snapshotPanelId": snapshot.id.uuidString,
            "stableSurfaceId": snapshot.stableSurfaceId?.uuidString ?? "",
            "type": snapshot.type.rawValue,
        ]
    }

    private func sessionRestoreLaunchKind(
        bindingLaunch: SurfaceResumeStartupLaunch?,
        agentLaunch: SurfaceResumeStartupLaunch?
    ) -> String {
        if let bindingLaunch {
            return bindingLaunch.initialCommand == nil ? "binding.input" : "binding.command"
        }
        if let agentLaunch {
            return agentLaunch.initialCommand == nil ? "agent.input" : "agent.command"
        }
        return "none"
    }

    private func sessionRestoreHasPlannedCommandLaunch(
        bindingLaunch: SurfaceResumeStartupLaunch?,
        agentLaunch: SurfaceResumeStartupLaunch?
    ) -> Bool {
        bindingLaunch?.initialCommand != nil || agentLaunch?.initialCommand != nil
    }

    private func sessionRestoreStartupKind(command: String?, input: String?) -> String {
        if command != nil { return "command" }
        if input != nil { return "input" }
        return "shell"
    }

    nonisolated static func resolvedSnapshotTerminalScrollback(
        capturedScrollback: String?,
        fallbackScrollback: String?,
        allowFallbackScrollback: Bool = true
    ) -> String? {
        makeSessionRestorePolicyService().resolvedSnapshotTerminalScrollback(
            capturedScrollback: capturedScrollback,
            fallbackScrollback: fallbackScrollback,
            allowFallbackScrollback: allowFallbackScrollback
        )
    }

    nonisolated static func shouldReplaySessionScrollback(
        restorableAgent: SessionRestorableAgentSnapshot?,
        tmuxStartCommand: String? = nil,
        hasResumeStartupWork: Bool = false
    ) -> Bool {
        makeSessionRestorePolicyService().shouldReplaySessionScrollback(
            hasRestorableAgent: restorableAgent != nil,
            tmuxStartCommand: tmuxStartCommand,
            hasResumeStartupWork: hasResumeStartupWork
        )
    }

    nonisolated static func shouldAutoConnectRestoredRemote(
        foregroundAuthToken: String?,
        snapshot: SessionWorkspaceSnapshot,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
    ) -> Bool {
        makeSessionRestorePolicyService().shouldAutoConnectRestoredRemote(
            foregroundAuthToken: foregroundAuthToken,
            snapshot: snapshot,
            isRunningUnderAutomatedTests: isRunningUnderAutomatedTests
        )
    }

    nonisolated static func surfaceResumeStartupInput(
        _ resumeBinding: SurfaceResumeBindingSnapshot?,
        autoResumeAgentSessions: Bool,
        allowLauncherScript: Bool = false,
        promptForApproval: Bool = true,
        approvalStoreURL: URL = SurfaceResumeApprovalStore.defaultURL(),
        approvalSigningSecret: Data? = nil
    ) -> String? {
        makeSessionRestorePolicyService().surfaceResumeStartupInput(
            resumeBinding,
            autoResumeAgentSessions: autoResumeAgentSessions,
            allowLauncherScript: allowLauncherScript,
            promptForApproval: promptForApproval,
            approvalStoreURL: approvalStoreURL,
            approvalSigningSecret: approvalSigningSecret
        )
    }

    nonisolated static func surfaceResumeStartupLaunch(
        _ resumeBinding: SurfaceResumeBindingSnapshot?,
        autoResumeAgentSessions: Bool,
        allowLauncherScript: Bool = true,
        promptForApproval: Bool = true,
        approvalStoreURL: URL = SurfaceResumeApprovalStore.defaultURL(),
        approvalSigningSecret: Data? = nil,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> SurfaceResumeStartupLaunch? {
        makeSessionRestorePolicyService(
            temporaryDirectory: temporaryDirectory
        ).surfaceResumeStartupLaunch(
            resumeBinding,
            autoResumeAgentSessions: autoResumeAgentSessions,
            allowLauncherScript: allowLauncherScript,
            promptForApproval: promptForApproval,
            approvalStoreURL: approvalStoreURL,
            approvalSigningSecret: approvalSigningSecret,
            fileManager: fileManager
        )
    }

    nonisolated static func resumeBindingForSessionRestore(
        _ binding: SurfaceResumeBindingSnapshot?,
        restorableAgent: SessionRestorableAgentSnapshot?
    ) -> SurfaceResumeBindingSnapshot? {
        guard let binding, binding.isAgentHookBinding, let restorableAgent else {
            return binding
        }
        guard binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines) == restorableAgent.sessionId else {
            return binding
        }
        if let bindingKind = binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bindingKind.isEmpty,
           RestorableAgentKind(rawValue: bindingKind) != restorableAgent.kind {
            return binding
        }

        // Restore has no live hook cwd; use the snapshot's derived restorable cwd
        // and fall back to launch capture only for older snapshots.
        let snapshotRestorableWorkingDirectory =
            restorableAgent.workingDirectory ?? restorableAgent.launchCommand?.workingDirectory
        let resolvedWorkingDirectory = AgentResumeWorkingDirectory().resolve(
            kind: binding.kind ?? restorableAgent.kind.rawValue,
            runtimeCwd: binding.cwd,
            launchWorkingDirectory: snapshotRestorableWorkingDirectory
        )
        guard resolvedWorkingDirectory != binding.cwd else {
            return binding
        }
        return binding.retargetingWorkingDirectory(resolvedWorkingDirectory)
    }

    nonisolated static func restorableAgentForSessionRestore(
        _ restorableAgent: SessionRestorableAgentSnapshot?,
        resumeBinding: SurfaceResumeBindingSnapshot?
    ) -> SessionRestorableAgentSnapshot? {
        guard let restorableAgent else { return nil }
        guard let resumeBinding, resumeBinding.isAgentHookBinding else {
            return restorableAgent
        }

        if let checkpointId = normalizedResumeBindingValue(resumeBinding.checkpointId),
           checkpointId != restorableAgent.sessionId {
            return nil
        }
        if let kindValue = normalizedResumeBindingValue(resumeBinding.kind) {
            guard let bindingKind = RestorableAgentKind(rawValue: kindValue),
                  bindingKind == restorableAgent.kind else {
                return nil
            }
        }
        return restorableAgent
    }

    nonisolated private static func normalizedResumeBindingValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    nonisolated static func restorableTmuxStartCommand(_ rawCommand: String?) -> String? {
        makeSessionRestorePolicyService().restorableTmuxStartCommand(rawCommand)
    }

    nonisolated static func shouldPersistSessionScrollback(
        shellActivityState: PanelShellActivityState?,
        fallbackNeedsConfirmClose: Bool
    ) -> Bool {
        makeSessionRestorePolicyService().shouldPersistSessionScrollback(
            closeConfirmationRequired: resolveCloseConfirmation(
                shellActivityState: shellActivityState,
                fallbackNeedsConfirmClose: fallbackNeedsConfirmClose
            )
        )
    }

    nonisolated static func resolveCloseConfirmation(
        shellActivityState: PanelShellActivityState?,
        fallbackNeedsConfirmClose: Bool
    ) -> Bool {
        switch shellActivityState ?? .unknown {
        case .promptIdle:
            return false
        case .commandRunning:
            return true
        case .unknown:
            return fallbackNeedsConfirmClose
        }
    }

    nonisolated static func makeSessionRestorePolicyService(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> WorkspaceSessionRestorePolicyService<SurfaceResumeBindingSnapshot> {
        WorkspaceSessionRestorePolicyService(
            applyStoredApproval: { binding, fileURL, signingSecret in
                SurfaceResumeApprovalStore.applyingStoredApproval(
                    to: binding,
                    fileURL: fileURL,
                    signingSecret: signingSecret
                )
            },
            shouldRunPromptedSurfaceResume: { binding in
                Self.shouldRunPromptedSurfaceResume(binding)
            },
            isRunningUnderAutomatedTests: {
                SessionRestorePolicy.isRunningUnderAutomatedTests()
            },
            truncateScrollback: { text in
                SessionPersistencePolicy.truncatedScrollback(text)
            },
            hermesCodexEnvironment: WorkspaceHermesCodexEnvironment(
                customBaseURLEnvironmentKey: HermesAgentCodexEnvironment.customBaseURLEnvironmentKey,
                defaultProvider: HermesAgentCodexEnvironment.defaultProvider,
                codexResponsesAPIMode: HermesAgentCodexEnvironment.codexResponsesAPIMode,
                applyingDefaultCodexBaseURL: { environment in
                    HermesAgentCodexEnvironment.applyingDefaultCodexBaseURL(to: environment)
                },
                resolvingDefaultCodexModel: { environment in
                    HermesAgentCodexEnvironment.defaultCodexModel(environment: environment)
                }
            ),
            temporaryDirectory: temporaryDirectory
        )
    }

    nonisolated private static func shouldRunPromptedSurfaceResume(_ binding: SurfaceResumeBindingSnapshot) -> Bool {
        guard Thread.isMainThread, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return false
        }
        return MainActor.assumeIsolated {
            shouldRunPromptedSurfaceResumeOnMain(binding)
        }
    }

    @MainActor
    private static func shouldRunPromptedSurfaceResumeOnMain(_ binding: SurfaceResumeBindingSnapshot) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "surfaceResumeApproval.runPrompt.title",
            defaultValue: "Run Resume Command?"
        )
        alert.informativeText = String(
            format: String(
                localized: "surfaceResumeApproval.runPrompt.message",
                defaultValue: "cmux is restoring a terminal with this resume command:\n\n%@\n\nWorking directory: %@"
            ),
            binding.command,
            binding.cwd ?? String(localized: "surfaceResumeApproval.cwd.none", defaultValue: "None")
        )
        alert.addButton(withTitle: String(localized: "surfaceResumeApproval.runPrompt.run", defaultValue: "Run"))
        alert.addButton(withTitle: String(localized: "surfaceResumeApproval.runPrompt.skip", defaultValue: "Skip"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension AppDelegate {
    /// Locates a terminal globally by runtime panel id first, then restart-stable surface id.
    func locateSurfaceResumeTarget(
        surfaceId targetId: UUID
    ) -> (windowId: UUID, workspaceId: UUID, surfaceId: UUID, tabManager: TabManager)? {
        if let located = locateSurface(surfaceId: targetId) {
            return (located.windowId, located.workspaceId, targetId, located.tabManager)
        }

        var match: (windowId: UUID, workspaceId: UUID, surfaceId: UUID, tabManager: TabManager)?
        var isAmbiguous = false
        var visitedManagers = Set<ObjectIdentifier>()

        func inspect(windowId: UUID, tabManager: TabManager) {
            guard !isAmbiguous,
                  visitedManagers.insert(ObjectIdentifier(tabManager)).inserted else {
                return
            }
            for workspace in tabManager.tabs {
                guard let surfaceId = workspace.terminalPanelIdForSurfaceResumeTarget(targetId) else {
                    continue
                }
                guard match == nil else {
                    isAmbiguous = true
                    return
                }
                match = (windowId, workspace.id, surfaceId, tabManager)
            }
        }

        for context in mainWindowContexts.values {
            inspect(windowId: context.windowId, tabManager: context.tabManager)
        }
        for route in recoverableMainWindowRoutes() {
            guard let tabManager = route.tabManager else { continue }
            inspect(windowId: route.windowId, tabManager: tabManager)
        }

        return isAmbiguous ? nil : match
    }
}
