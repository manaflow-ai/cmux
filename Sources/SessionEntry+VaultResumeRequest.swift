import CMUXAgentLaunch

/// Adapts app-owned Vault values to the package's pure resume planner.
extension SessionEntry {
    /// Compatibility adapter for the shared Codex command renderer.
    static func codexApprovalSandboxArgumentTokens(
        approvalPolicy: String?,
        sandboxMode: String?
    ) -> [String] {
        VaultResumeLaunchPlanner().codexApprovalSandboxArgumentTokens(
            approvalPolicy: approvalPolicy,
            sandboxMode: sandboxMode
        )
    }

    /// Projects the app-owned entry into package-owned immutable launch input.
    var vaultResumeLaunchRequest: VaultResumeLaunchRequest {
        VaultResumeLaunchRequest(
            kind: agent.rawValue,
            sessionID: sessionId,
            workingDirectory: resumeWorkingDirectory,
            profile: vaultResumeAgentProfile,
            legacyCommand: vaultResumeCompatibilityCommand
        )
    }

    /// Converts the app's associated-value model to the package profile enum.
    private var vaultResumeAgentProfile: VaultResumeLaunchRequest.AgentProfile {
        switch specifics {
        case let .claude(model, permissionMode, configDirectoryForResume):
            .claude(
                model: model,
                permissionMode: permissionMode,
                configDirectory: configDirectoryForResume
            )
        case let .codex(model, approvalPolicy, sandboxMode, effort):
            .codex(
                model: model,
                approvalPolicy: approvalPolicy,
                sandboxMode: sandboxMode,
                effort: effort
            )
        case let .grok(model, permissionMode, sandboxMode, grokHome):
            .grok(
                model: model,
                permissionMode: permissionMode,
                sandboxMode: sandboxMode,
                grokHome: grokHome
            )
        case let .opencode(providerModel, agentName):
            .opencode(providerModel: providerModel, agentName: agentName)
        case .rovodev:
            .rovodev
        case let .hermesAgent(source, model, hermesHome):
            .hermesAgent(source: source, model: model, hermesHome: hermesHome)
        case let .registered(registration, launchCommand):
            .registered(
                vaultResumeRegistration(registration),
                launchCommand: launchCommand
            )
        }
    }

    /// Copies only registration fields needed by the pure planner.
    private func vaultResumeRegistration(
        _ registration: CmuxVaultAgentRegistration
    ) -> VaultResumeLaunchRequest.Registration {
        VaultResumeLaunchRequest.Registration(
            id: registration.id,
            defaultExecutable: registration.defaultExecutable,
            resumeCommand: registration.resumeCommand,
            workingDirectoryPolicy: registration.cwd == .ignore ? .ignore : .preserve,
            sessionDirectory: registration.sessionDirectory,
            registeredResumeKind: registration.registeredResumeKind?.rawValue
        )
    }
}
