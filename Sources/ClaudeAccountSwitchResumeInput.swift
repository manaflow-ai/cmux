import CMUXAgentLaunch
import Foundation

/// The shell input that resumes a Claude session under the account a switch plan targets.
///
/// The command replays the plan's launch environment, so it names the target's
/// `CLAUDE_CONFIG_DIR` (none for the default account) and never the source's. A snapshot
/// without a launch capture yields a plain resume; the respawned shell's environment
/// already selects the account then.
struct ClaudeAccountSwitchResumeInput {
    let snapshot: SessionRestorableAgentSnapshot
    let plan: ClaudeAccountSwitchPlan

    /// The input to type into the respawned shell, ending in a newline, or `nil` when the
    /// session cannot be resumed.
    func typedInput(dialect: TerminalStartupShellDialect = .loginShell) -> String? {
        var launchCommand = snapshot.launchCommand
        launchCommand?.environment = plan.launchEnvironment
        guard let command = AgentResumeCommandBuilder.resumeShellCommand(
            kind: snapshot.kind,
            sessionId: plan.sessionID,
            launchCommand: launchCommand,
            resolvedWorkingDirectory: plan.workingDirectory,
            discardRecordedCwdOptions: false,
            registrationOverride: snapshot.registration,
            observedPermissionMode: snapshot.permissionMode
        ) else {
            return nil
        }
        return TerminalStartupTypedShellCommand(dialect: dialect).typedInput(posixCommand: command) + "\n"
    }
}
