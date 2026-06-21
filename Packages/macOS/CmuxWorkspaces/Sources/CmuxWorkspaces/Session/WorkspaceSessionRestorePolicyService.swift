public import Foundation

/// Service that owns workspace session restore policy decisions.
///
/// The app target injects concrete approval storage, prompt handling, automated
/// test detection, scrollback truncation, and Hermes Codex defaults. That keeps
/// this package independent of app DTO storage and UI while preserving the
/// exact restore behavior.
public struct WorkspaceSessionRestorePolicyService<Binding: WorkspaceSurfaceResumeBinding>: Sendable {
    private let applyStoredApproval: @Sendable (Binding, URL, Data?) -> Binding
    private let shouldRunPromptedSurfaceResume: @Sendable (Binding) -> Bool
    private let isRunningUnderAutomatedTests: @Sendable () -> Bool
    private let truncateScrollback: @Sendable (String?) -> String?
    private let hermesCodexEnvironment: WorkspaceHermesCodexEnvironment
    private let temporaryDirectory: URL

    /// Creates a restore policy service.
    public init(
        applyStoredApproval: @escaping @Sendable (Binding, URL, Data?) -> Binding,
        shouldRunPromptedSurfaceResume: @escaping @Sendable (Binding) -> Bool,
        isRunningUnderAutomatedTests: @escaping @Sendable () -> Bool,
        truncateScrollback: @escaping @Sendable (String?) -> String?,
        hermesCodexEnvironment: WorkspaceHermesCodexEnvironment,
        temporaryDirectory: URL
    ) {
        self.applyStoredApproval = applyStoredApproval
        self.shouldRunPromptedSurfaceResume = shouldRunPromptedSurfaceResume
        self.isRunningUnderAutomatedTests = isRunningUnderAutomatedTests
        self.truncateScrollback = truncateScrollback
        self.hermesCodexEnvironment = hermesCodexEnvironment
        self.temporaryDirectory = temporaryDirectory
    }

    /// Resolves the scrollback text persisted for a terminal snapshot.
    public func resolvedSnapshotTerminalScrollback(
        capturedScrollback: String?,
        fallbackScrollback: String?,
        allowFallbackScrollback: Bool = true
    ) -> String? {
        if let captured = truncateScrollback(capturedScrollback) {
            return captured
        }
        guard allowFallbackScrollback else { return nil }
        return truncateScrollback(fallbackScrollback)
    }

    /// Returns whether restored scrollback should be replayed for a terminal.
    public func shouldReplaySessionScrollback(
        hasRestorableAgent: Bool,
        tmuxStartCommand: String? = nil,
        hasResumeStartupWork: Bool = false
    ) -> Bool {
        !hasRestorableAgent && restorableTmuxStartCommand(tmuxStartCommand) == nil && !hasResumeStartupWork
    }

    /// Returns whether a restored remote workspace should auto-connect.
    public func shouldAutoConnectRestoredRemote<Snapshot: WorkspaceSessionRemoteRestoreSnapshot>(
        foregroundAuthToken: String?,
        snapshot: Snapshot,
        isRunningUnderAutomatedTests overrideIsRunningUnderAutomatedTests: Bool? = nil
    ) -> Bool {
        let runningUnderTests = overrideIsRunningUnderAutomatedTests ?? isRunningUnderAutomatedTests()
        guard !runningUnderTests else { return false }
        let normalizedForegroundAuthToken = foregroundAuthToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedForegroundAuthToken?.isEmpty == false else { return true }
        let hasTerminalThatWillAuthenticateReconnect = snapshot.panels.contains {
            guard let terminal = $0.terminal else { return false }
            if terminal.isRemoteTerminal != false {
                return true
            }
            let remotePTYSessionID = terminal.remotePTYSessionID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return remotePTYSessionID?.isEmpty == false
        }
        return !hasTerminalThatWillAuthenticateReconnect
    }

    /// Returns startup input for an approved restored surface resume binding.
    public func surfaceResumeStartupInput(
        _ resumeBinding: Binding?,
        autoResumeAgentSessions: Bool,
        allowLauncherScript: Bool = false,
        promptForApproval: Bool = true,
        approvalStoreURL: URL,
        approvalSigningSecret: Data? = nil,
        fileManager: FileManager = .default
    ) -> String? {
        guard let effectiveBinding = approvedSurfaceResumeBinding(
            resumeBinding,
            autoResumeAgentSessions: autoResumeAgentSessions,
            promptForApproval: promptForApproval,
            approvalStoreURL: approvalStoreURL,
            approvalSigningSecret: approvalSigningSecret
        ) else {
            return nil
        }
        return effectiveBinding.startupInputWithLauncherScript(
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory,
            allowLauncherScript: allowLauncherScript
        )
    }

    /// Returns the command or input launch action for a restored surface resume binding.
    public func surfaceResumeStartupLaunch(
        _ resumeBinding: Binding?,
        autoResumeAgentSessions: Bool,
        allowLauncherScript: Bool = true,
        promptForApproval: Bool = true,
        approvalStoreURL: URL,
        approvalSigningSecret: Data? = nil,
        fileManager: FileManager = .default
    ) -> WorkspaceSurfaceResumeStartupLaunch? {
        guard let effectiveBinding = approvedSurfaceResumeBinding(
            resumeBinding,
            autoResumeAgentSessions: autoResumeAgentSessions,
            promptForApproval: promptForApproval,
            approvalStoreURL: approvalStoreURL,
            approvalSigningSecret: approvalSigningSecret
        ) else {
            return nil
        }
        return surfaceResumeStartupLaunch(
            forApprovedBinding: effectiveBinding,
            allowLauncherScript: allowLauncherScript,
            fileManager: fileManager
        )
    }

    /// Returns the command or input launch action for an already approved binding.
    public func surfaceResumeStartupLaunch(
        forApprovedBinding effectiveBinding: Binding,
        allowLauncherScript: Bool = true,
        fileManager: FileManager = .default
    ) -> WorkspaceSurfaceResumeStartupLaunch? {
        if effectiveBinding.isAgentHookBinding,
           allowLauncherScript,
           let command = effectiveBinding.startupCommandWithLauncherScript(
               fileManager: fileManager,
               temporaryDirectory: temporaryDirectory
           ) {
            return .command(command)
        }
        guard let input = effectiveBinding.startupInputWithLauncherScript(
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory,
            allowLauncherScript: allowLauncherScript
        ) else {
            return nil
        }
        return .input(input)
    }

    /// Applies stored approval state and returns the binding allowed to run.
    public func approvedSurfaceResumeBinding(
        _ resumeBinding: Binding?,
        autoResumeAgentSessions: Bool,
        promptForApproval: Bool = true,
        approvalStoreURL: URL,
        approvalSigningSecret: Data? = nil
    ) -> Binding? {
        guard let resumeBinding else { return nil }
        var effectiveBinding = applyStoredApproval(resumeBinding, approvalStoreURL, approvalSigningSecret)
        effectiveBinding = WorkspaceHermesAgentCommandBootstrapper(
            hermesCodexEnvironment: hermesCodexEnvironment
        ).bindingForStartup(effectiveBinding)
        if effectiveBinding.source == "agent-hook", !autoResumeAgentSessions {
            return nil
        }
        if effectiveBinding.requiresPromptApproval {
            guard promptForApproval else { return nil }
            guard shouldRunPromptedSurfaceResume(effectiveBinding) else { return nil }
            return effectiveBinding
        }
        guard effectiveBinding.allowsAutomaticResume else { return nil }
        return effectiveBinding
    }

    /// Returns a restorable tmux start command when the command launches an OMX HUD.
    public func restorableTmuxStartCommand(_ rawCommand: String?) -> String? {
        WorkspaceHermesAgentCommandBootstrapper(
            hermesCodexEnvironment: hermesCodexEnvironment
        ).restorableTmuxStartCommand(rawCommand)
    }

    /// Returns whether terminal scrollback should be persisted when closing/restoring.
    public func shouldPersistSessionScrollback(closeConfirmationRequired: Bool) -> Bool {
        !closeConfirmationRequired
    }
}
