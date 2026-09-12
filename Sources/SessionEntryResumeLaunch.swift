import CMUXAgentLaunch
import Foundation

/// The app-owned terminal startup value shared by every Vault resume surface.
nonisolated struct SessionEntryResumeLaunch: Sendable {
    /// How the terminal starts the selected Vault session.
    typealias Strategy = VaultResumeLaunchPlan.Strategy

    /// Why a launch had to use the explicitly bounded compatibility command.
    typealias LegacyFallbackReason = VaultResumeLaunchPlan.LegacyFallbackReason

    /// Maximum UTF-8 payload permitted for the rendered compatibility command.
    nonisolated static let maximumLegacyResumeInputBytes =
        VaultResumeLaunchPlan.maximumLegacyResumeInputBytes

    /// The selected structured or compatibility launch strategy.
    let strategy: Strategy
    /// Input queued into the new terminal, including its trailing return.
    let initialInput: String
    /// The directory requested for the new terminal surface.
    let workingDirectory: String?
    /// Lifecycle state used by the restore responder and session persistence.
    let startupRestoreAgent: SessionRestorableAgentSnapshot?
    /// Non-nil only for the enumerated compatibility strategy.
    let legacyFallbackReason: LegacyFallbackReason?

    private let plan: VaultResumeLaunchPlan

    /// Creates the app launch value from a package-owned immutable plan.
    init(
        plan: VaultResumeLaunchPlan,
        startupRestoreAgent: SessionRestorableAgentSnapshot?
    ) {
        self.plan = plan
        strategy = plan.strategy
        initialInput = plan.startupInput(for: Self.packageDialect(.loginShell))
        workingDirectory = plan.workingDirectory
        self.startupRestoreAgent = startupRestoreAgent
        legacyFallbackReason = plan.legacyFallbackReason
    }

    /// Renders the same immutable plan for a local or remote destination shell.
    func startupInput(for dialect: TerminalStartupShellDialect) -> String {
        plan.startupInput(for: Self.packageDialect(dialect))
    }

    /// Maps the app shell dialect to the package planner's value dialect.
    private static func packageDialect(
        _ dialect: TerminalStartupShellDialect
    ) -> VaultResumeShellDialect {
        switch dialect {
        case .posix:
            .posix
        case .nushell:
            .nushell
        }
    }
}

extension SessionEntry {
    /// Builds a structured restore record and selector, or the package's
    /// explicitly bounded compatibility result.
    var resumeLaunch: SessionEntryResumeLaunch? {
        let request = vaultResumeLaunchRequest
        guard let plan = VaultResumeLaunchPlanner().plan(for: request) else { return nil }
        guard let structured = plan.structuredSnapshot else {
            return SessionEntryResumeLaunch(plan: plan, startupRestoreAgent: nil)
        }

        let registration = normalizedRegistration(from: structured.registration)
        guard let kind = RestorableAgentKind(
            persistedRawValue: structured.kind,
            registration: registration
        ) else {
            return nil
        }
        let snapshot = SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: structured.sessionID,
            workingDirectory: structured.workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                arguments: structured.launchArguments,
                workingDirectory: structured.workingDirectory,
                environment: structured.environment.isEmpty ? nil : structured.environment,
                source: "vault"
            ),
            registration: registration,
            permissionMode: structured.permissionMode
        )
        guard snapshot.preparedResumeArguments(
            launchCommand: snapshot.launchCommand,
            workingDirectory: snapshot.workingDirectory,
            observedPermissionMode: snapshot.permissionMode
        ) == structured.preparedResumeArguments else {
            return nil
        }
        return SessionEntryResumeLaunch(plan: plan, startupRestoreAgent: snapshot)
    }

    /// Rehydrates a normalized package registration without moving app
    /// persistence types into the launch package.
    private func normalizedRegistration(
        from projection: VaultResumeLaunchRequest.Registration?
    ) -> CmuxVaultAgentRegistration? {
        guard let projection,
              case .registered(var registration, _) = specifics,
              projection.id == registration.id else {
            return nil
        }
        registration.resumeCommand = projection.resumeCommand
        return registration
    }
}
