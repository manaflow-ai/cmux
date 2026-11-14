import CMUXAgentLaunch
import Foundation

/// The shell input that resumes a Claude session with a session priority target applied.
///
/// The effort rides on `CLAUDE_CODE_EFFORT_LEVEL` in the command's launch environment, because
/// Claude Code's `/effort` would write the level into the user's settings file. Next to it,
/// `CMUX_SESSION_PRIORITY_EFFORT` holds the same level, so the resumed Claude's recorded launch
/// reads as cmux's, not the user's (``SessionPriorityManualSignal/launchEnvironmentEffort``). The model rides
/// on a `--model` argument that replaces any the launch recorded. Everything else the launch
/// recorded, the account's `CLAUDE_CONFIG_DIR` included, is replayed unchanged.
///
/// The restarted shell re-runs rc files and direnv, which can export an account key the pane runs
/// without (an account switch cleared it), so Claude runs under `env -u` for each such key the
/// recorded launch does not set itself. The pane stays on its account.
struct SessionPriorityResumeInput {
    let snapshot: SessionRestorableAgentSnapshot
    let target: SessionPriorityTarget
    let workingDirectory: String
    /// The account keys the pane runs without (``ClaudeAccountPaneEnvironment/clearedKeys``).
    let clearedEnvironmentKeys: [String]

    init(
        snapshot: SessionRestorableAgentSnapshot,
        target: SessionPriorityTarget,
        workingDirectory: String,
        clearedEnvironmentKeys: [String] = []
    ) {
        self.snapshot = snapshot
        self.target = target
        self.workingDirectory = workingDirectory
        self.clearedEnvironmentKeys = clearedEnvironmentKeys
    }

    /// The input to type into the restarted shell, ending in a newline, or `nil` when the session
    /// cannot be resumed with the target.
    ///
    /// Input past Fork's inline limit runs from a one-shot launcher script written under
    /// `temporaryDirectory`, because a canonical-mode tty drops a line past about 1024 bytes.
    func typedInput(
        dialect: TerminalStartupShellDialect = .loginShell,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> String? {
        snapshot.startupInput(
            command: posixCommand(),
            // The command carries its own `cd` prefix.
            workingDirectory: nil,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory,
            dialect: dialect
        )
    }

    /// `cd <dir> && env -u <cleared keys> <resume command>`, where the resume command replays the
    /// launch with `CLAUDE_CODE_EFFORT_LEVEL=<level>` (marked by `CMUX_SESSION_PRIORITY_EFFORT`)
    /// and `--model <model>`, or `nil` when the
    /// session cannot be resumed with the target.
    ///
    /// A target component needs the launch capture to ride on: without one the resume would run
    /// without it, and the pane would be restarted again for the same target.
    func posixCommand() -> String? {
        guard var launchCommand = snapshot.launchCommand else {
            return target.isEmpty ? resumeCommand(launchCommand: nil) : nil
        }
        if let effort = target.effort {
            var environment = launchCommand.environment ?? [:]
            environment[ClaudeEffortLevel.environmentKey] = effort.rawValue
            // Marks the level as cmux's, so it is not read back as the user's own.
            environment[ClaudeEffortLevel.sessionPriorityMarkerKey] = effort.rawValue
            launchCommand.environment = environment
        }
        if let model = target.model {
            // A capture without an argv has no executable to add the option to.
            guard !launchCommand.arguments.isEmpty else { return nil }
            launchCommand.arguments = SessionPriorityLaunchArguments.replacing(
                option: "--model",
                with: model,
                in: launchCommand.arguments
            )
        }
        return resumeCommand(launchCommand: launchCommand)
    }

    private func resumeCommand(launchCommand: AgentLaunchCommandSnapshot?) -> String? {
        guard let resumeCommand = AgentResumeCommandBuilder.resumeShellCommand(
            kind: snapshot.kind,
            sessionId: snapshot.sessionId,
            launchCommand: launchCommand,
            resolvedWorkingDirectory: workingDirectory,
            discardRecordedCwdOptions: false,
            registrationOverride: snapshot.registration,
            includeWorkingDirectoryPrefix: false,
            observedPermissionMode: snapshot.permissionMode
        ) else {
            return nil
        }
        let unsetArguments = unsetEnvironmentKeys(launchEnvironment: launchCommand?.environment)
            .flatMap { ["-u", $0] }
        let command = unsetArguments.isEmpty
            ? resumeCommand
            : (["env"] + unsetArguments + [resumeCommand]).joined(separator: " ")
        // The builder's own prefix rule: a registration that ignores the cwd gets no `cd`.
        let prefixDirectory = snapshot.registration?.cwd == .ignore ? nil : workingDirectory
        return TerminalStartupWorkingDirectoryPrefix.prefix(command, workingDirectory: prefixDirectory)
    }

    /// The cleared keys the replayed launch environment does not set, sorted so the command is
    /// stable. A key the recorded launch sets is the account the session ran under.
    private func unsetEnvironmentKeys(launchEnvironment: [String: String]?) -> [String] {
        Set(clearedEnvironmentKeys)
            .filter { launchEnvironment?[$0]?.isEmpty ?? true }
            .sorted()
    }
}
