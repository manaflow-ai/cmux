import CMUXAgentLaunch
import Foundation

/// The terminal startup plan shared by every Vault resume entry point.
struct SessionEntryResumeLaunch: Sendable {
    /// How the terminal starts the selected Vault session.
    enum Strategy: Sendable, Equatable {
        /// Resolve structured argv and environment through `cmux restore`.
        case restoreVerb
        /// Type the quarantined copyable command for an unsupported registration.
        case legacyCommand
    }

    /// The selected structured or compatibility launch strategy.
    let strategy: Strategy
    /// Input queued into the new terminal, including its trailing return.
    let initialInput: String
    /// The directory requested for the new terminal surface.
    let workingDirectory: String?
    /// Lifecycle state used by the restore responder and session persistence.
    let startupRestoreAgent: SessionRestorableAgentSnapshot?
}

/// Agent-specific launch fields used to assemble one restorable snapshot.
private struct SessionEntryResumeSnapshotComponents {
    /// Captured executable and option arguments before resume arguments are applied.
    let arguments: [String]
    /// Replay-safe environment required by the agent profile.
    let environment: [String: String]
    /// Registration metadata for custom Vault agents.
    let registration: CmuxVaultAgentRegistration?
    /// Captured permission mode when the agent exposes one separately from argv.
    let permissionMode: String?
}

extension SessionEntry {
    /// Builds the same surface-scoped restore selector used by relaunch restore.
    ///
    /// Registered agents deliberately fall back to the quarantined copyable
    /// shell command only when their registration cannot produce structured argv.
    var resumeLaunch: SessionEntryResumeLaunch? {
        guard let snapshot = vaultResumeSnapshot else {
            return legacyResumeLaunch
        }
        if let preparedArguments = snapshot.preparedResumeArguments(
            launchCommand: snapshot.launchCommand,
            workingDirectory: snapshot.workingDirectory,
            observedPermissionMode: snapshot.permissionMode
        ), !preparedArguments.isEmpty,
           let initialInput = snapshot.resumeStartupInput(useLocalRestoreVerb: true) {
            return SessionEntryResumeLaunch(
                strategy: .restoreVerb,
                initialInput: initialInput,
                workingDirectory: resumeWorkingDirectory,
                startupRestoreAgent: snapshot
            )
        }

        return legacyResumeLaunch
    }

    /// Builds the explicit compatibility launch for an unsupported registration.
    /// The legacy command is a POSIX one-liner typed into the user's shell, so
    /// it goes through the typed-boundary dialect wrap (nushell cannot parse
    /// POSIX; the `restoreVerb` strategy types only bare words and needs none).
    private var legacyResumeLaunch: SessionEntryResumeLaunch? {
        guard let legacyCommand = copyResumeCommand else { return nil }
        return SessionEntryResumeLaunch(
            strategy: .legacyCommand,
            initialInput: TerminalStartupTypedShellCommand().typedInput(posixCommand: legacyCommand) + "\n",
            workingDirectory: resumeWorkingDirectory,
            startupRestoreAgent: nil
        )
    }

    /// Converts this Vault record into the lifecycle snapshot consumed by restore.
    private var vaultResumeSnapshot: SessionRestorableAgentSnapshot? {
        let components: SessionEntryResumeSnapshotComponents
        switch specifics {
        case let .claude(model, permissionMode, configDirectoryForResume):
            var arguments = ["claude"]
            if let model = Self.nonEmptyResumeValue(model) {
                arguments.append(contentsOf: ["--model", model])
            }
            let environment = Self.nonEmptyResumeValue(configDirectoryForResume)
                .map { ["CLAUDE_CONFIG_DIR": $0] } ?? [:]
            components = SessionEntryResumeSnapshotComponents(
                arguments: arguments,
                environment: environment,
                registration: nil,
                permissionMode: Self.nonEmptyResumeValue(permissionMode)
            )
        case let .codex(model, approvalPolicy, sandboxMode, effort):
            var arguments = ["codex"]
            if let model = Self.nonEmptyResumeValue(model) {
                arguments.append(contentsOf: ["-m", model])
            }
            arguments.append(contentsOf: Self.codexApprovalSandboxArgumentTokens(
                approvalPolicy: approvalPolicy,
                sandboxMode: sandboxMode
            ))
            if let effort = Self.nonEmptyResumeValue(effort) {
                arguments.append(contentsOf: ["-c", "model_reasoning_effort=\(effort)"])
            }
            components = SessionEntryResumeSnapshotComponents(
                arguments: arguments,
                environment: [:],
                registration: nil,
                permissionMode: nil
            )
        case let .grok(model, permissionMode, sandboxMode, grokHome):
            var arguments = ["grok"]
            if let model = Self.nonEmptyResumeValue(model) {
                arguments.append(contentsOf: ["-m", model])
            }
            if let permissionMode = Self.nonEmptyResumeValue(permissionMode) {
                arguments.append(contentsOf: ["--permission-mode", permissionMode])
            }
            if let sandboxMode = Self.nonEmptyResumeValue(sandboxMode) {
                arguments.append(contentsOf: ["--sandbox", sandboxMode])
            }
            let environment = Self.nonEmptyResumeValue(grokHome)
                .map { ["GROK_HOME": $0] } ?? [:]
            components = SessionEntryResumeSnapshotComponents(
                arguments: arguments,
                environment: environment,
                registration: nil,
                permissionMode: nil
            )
        case let .opencode(providerModel, agentName):
            var arguments = ["opencode"]
            if let providerModel = Self.nonEmptyResumeValue(providerModel) {
                arguments.append(contentsOf: ["-m", providerModel])
            }
            if let agentName = Self.nonEmptyResumeValue(agentName) {
                arguments.append(contentsOf: ["--agent", agentName])
            }
            components = SessionEntryResumeSnapshotComponents(
                arguments: arguments,
                environment: [:],
                registration: nil,
                permissionMode: nil
            )
        case .rovodev:
            components = SessionEntryResumeSnapshotComponents(
                arguments: ["acli", "rovodev", "run"],
                environment: [:],
                registration: nil,
                permissionMode: nil
            )
        case let .hermesAgent(source, model, hermesHome):
            var arguments = ["hermes"]
            if source == "tui" {
                arguments.append("--tui")
            }
            if let model = Self.nonEmptyResumeValue(model) {
                arguments.append(contentsOf: ["--model", model])
            }
            let environment = Self.nonEmptyResumeValue(hermesHome)
                .map { ["HERMES_HOME": $0] } ?? [:]
            components = SessionEntryResumeSnapshotComponents(
                arguments: arguments,
                environment: environment,
                registration: nil,
                permissionMode: nil
            )
        case .registered(let registration):
            components = SessionEntryResumeSnapshotComponents(
                arguments: [registration.defaultExecutable],
                environment: [:],
                registration: registration,
                permissionMode: nil
            )
        }

        guard let kind = RestorableAgentKind(
            persistedRawValue: agent.rawValue,
            registration: components.registration
        ) else {
            return nil
        }
        let workingDirectory = resumeWorkingDirectory
        return SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                arguments: components.arguments,
                workingDirectory: workingDirectory,
                environment: components.environment.isEmpty ? nil : components.environment,
                source: "vault"
            ),
            registration: components.registration,
            permissionMode: components.permissionMode
        )
    }

    /// Sandbox-policy values the Codex CLI `--sandbox` flag accepts.
    ///
    /// cmux captures Codex's internal sandbox-policy `type`, which also includes
    /// values such as `disabled` and `managed` that the CLI rejects.
    private static let codexCLISandboxModes: Set<String> = [
        "read-only",
        "workspace-write",
        "danger-full-access",
    ]

    /// Returns a structured argument vector for the captured Codex policy.
    ///
    /// The captured `(approval: "never", sandbox: "disabled")` pair is the exact
    /// inverse of `--dangerously-bypass-approvals-and-sandbox`, so it becomes that
    /// one flag instead of the invalid `-a never -s disabled` combination.
    static func codexApprovalSandboxArgumentTokens(
        approvalPolicy: String?,
        sandboxMode: String?
    ) -> [String] {
        if approvalPolicy == "never", sandboxMode == "disabled" {
            return ["--dangerously-bypass-approvals-and-sandbox"]
        }

        var arguments: [String] = []
        if let approvalPolicy, !approvalPolicy.isEmpty {
            arguments.append(contentsOf: ["-a", approvalPolicy])
        }
        if let sandboxMode, !sandboxMode.isEmpty,
           codexCLISandboxModes.contains(sandboxMode) {
            arguments.append(contentsOf: ["-s", sandboxMode])
        }
        return arguments
    }

    /// Normalizes optional Vault metadata before it enters structured launch state.
    private static func nonEmptyResumeValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
