import AppKit
import CMUXAgentLaunch
import CmuxWorkspaces
import Foundation

extension Workspace {
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
