import CMUXAgentLaunch
import Foundation

/// The shell input that resumes a Claude session under the account a switch plan targets.
///
/// The command replays the plan's launch environment, so it names the target's
/// `CLAUDE_CONFIG_DIR` (none for the default account) and never the source's. The respawned
/// shell re-runs rc files and direnv, which can export an account key again, so Claude runs
/// under `env -u` for every key the plan clears. A snapshot without a launch capture yields a
/// plain resume; the respawned shell's environment already selects the account then.
struct ClaudeAccountSwitchResumeInput {
    let snapshot: SessionRestorableAgentSnapshot
    let plan: ClaudeAccountSwitchPlan

    /// The input to type into the respawned shell, ending in a newline, or `nil` when the
    /// session cannot be resumed.
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

    /// `cd <dir> && env -u <cleared keys> <resume command>`, or `nil` when the session
    /// cannot be resumed.
    func posixCommand() -> String? {
        var launchCommand = snapshot.launchCommand
        launchCommand?.environment = plan.launchEnvironment
        guard let resumeCommand = AgentResumeCommandBuilder.resumeShellCommand(
            kind: snapshot.kind,
            sessionId: plan.sessionID,
            launchCommand: launchCommand,
            resolvedWorkingDirectory: plan.workingDirectory,
            discardRecordedCwdOptions: false,
            registrationOverride: snapshot.registration,
            includeWorkingDirectoryPrefix: false,
            observedPermissionMode: snapshot.permissionMode
        ) else {
            return nil
        }
        let unsetArguments = clearedEnvironmentKeys.flatMap { ["-u", $0] }
        let command = unsetArguments.isEmpty
            ? resumeCommand
            : (["env"] + unsetArguments + [resumeCommand]).joined(separator: " ")
        // The builder's own prefix rule: a registration that ignores the cwd gets no `cd`.
        let workingDirectory = snapshot.registration?.cwd == .ignore ? nil : plan.workingDirectory
        return TerminalStartupWorkingDirectoryPrefix.prefix(command, workingDirectory: workingDirectory)
    }

    /// The account keys the plan clears, sorted so the command is stable.
    private var clearedEnvironmentKeys: [String] {
        plan.surfaceEnvironmentOverrides.filter { $0.value.isEmpty }.keys.sorted()
    }
}
