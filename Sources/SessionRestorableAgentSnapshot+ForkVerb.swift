import CMUXAgentLaunch
import Foundation

extension SessionRestorableAgentSnapshot {
    /// Renders the compatibility fork command for a destination working directory.
    func forkCommand(restoringWorkingDirectory: String?) -> String? {
        guard kind.restoreMode == .resumeSession else { return nil }
        return AgentResumeCommandBuilder.forkShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: restoringWorkingDirectory ?? workingDirectory,
            registrationOverride: registration,
            observedPermissionMode: permissionMode
        )
    }

    /// Returns a fork snapshot retargeted to the directory selected by the
    /// destination surface while preserving the captured launch metadata.
    func retargetingForkWorkingDirectory(_ workingDirectory: String?) -> Self {
        var retargeted = self
        retargeted.workingDirectory = workingDirectory
        if var launchCommand = retargeted.launchCommand {
            launchCommand.workingDirectory = workingDirectory
            retargeted.launchCommand = launchCommand
        }
        return retargeted
    }

    /// Builds the shell-free fork argv used by the `cmux fork` record path.
    ///
    /// The app and CLI share the same `AgentForkArgv` rules. Registry-owned agents
    /// are expanded here while the snapshot still carries their registration; the
    /// resulting argv is persisted in the surface restore record for the CLI.
    func preparedForkArguments(
        launchCommand: AgentLaunchCommandSnapshot? = nil,
        workingDirectory: String? = nil,
        observedPermissionMode: String? = nil
    ) -> [String]? {
        guard kind.restoreMode == .resumeSession else { return nil }
        return AgentResumeCommandBuilder.forkArguments(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand ?? self.launchCommand,
            workingDirectory: workingDirectory ?? self.workingDirectory,
            customRegistration: registration,
            observedPermissionMode: observedPermissionMode ?? permissionMode
        )
    }

    /// Returns a compact `cmux fork` selector for a local startup shell.
    ///
    /// When `useLocalForkVerb` is false, this preserves the existing rendered
    /// shell command behavior for hosts where the local cmux CLI is not reachable
    /// (for example an SSH tmux mirror).
    func forkStartupInput(
        useLocalForkVerb: Bool,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        allowLauncherScript: Bool = true,
        dialect: TerminalStartupShellDialect = .loginShell
    ) -> String? {
        guard useLocalForkVerb else {
            return forkStartupInput(
                fileManager: fileManager,
                temporaryDirectory: temporaryDirectory,
                allowLauncherScript: allowLauncherScript,
                dialect: dialect
            )
        }
        guard preparedForkArguments() != nil else { return nil }

        let executable = AgentRestoreLaunch.cliStartupExecutableToken
        guard let kind = AgentRestoreCLIArgument(rawValue: self.kind.rawValue),
              let sessionID = AgentRestoreCLIArgument(rawValue: self.sessionId) else {
            return " \(executable) fork --surface\n"
        }
        return " \(executable) fork \(kind.rawValue) \(sessionID.rawValue)\n"
    }
}
