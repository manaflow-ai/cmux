import CMUXAgentLaunch
import Foundation

/// Builds shell commands for agents whose upstream CLI can only start a fresh conversation.
struct AgentRelaunchCommandBuilder {
    /// Returns a sanitized command-level restore in the captured working directory.
    ///
    /// Ollama has no session identifier or resume verb. Relaunch restores the
    /// executable, model, safe flags, and cwd, but starts a fresh conversation.
    func shellCommand(
        kind: RestorableAgentKind,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?
    ) -> String? {
        guard kind.restoreMode == .relaunchCommand,
              let launchCommand,
              let argv = AgentResumeArgv().builtInRelaunchKind(
                  kind: kind.rawValue,
                  executablePath: launchCommand.executablePath,
                  arguments: launchCommand.arguments
              ),
              !argv.isEmpty else {
            return nil
        }

        var commandParts: [String] = []
        let environment = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: launchCommand.environment ?? [:],
            kind: kind.rawValue
        )
        if !environment.isEmpty {
            commandParts.append("env")
            commandParts.append(contentsOf: environment.keys.sorted().compactMap { key in
                environment[key].map { "\(key)=\($0)" }
            })
        }
        commandParts.append(contentsOf: argv)

        let command = commandParts
            .map { TerminalStartupShellQuoting.singleQuoted($0) }
            .joined(separator: " ")
        return TerminalStartupWorkingDirectoryPrefix.prefix(
            command,
            workingDirectory: workingDirectory ?? launchCommand.workingDirectory
        )
    }
}
