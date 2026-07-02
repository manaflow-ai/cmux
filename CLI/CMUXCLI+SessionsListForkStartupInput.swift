import Foundation
import CMUXAgentLaunch

extension CMUXCLI {
    func sessionsListForkStartupInputAvailable(
        arguments: [String],
        agent: String,
        record: ClaudeHookSessionRecord,
        launchCommand: AgentHookLaunchCommandRecord?
    ) -> Bool {
        let command = sessionsListForkShellCommand(
            arguments: arguments,
            agent: agent,
            record: record,
            launchCommand: launchCommand
        )
        return (command + "\n").utf8.count <= 900
    }

    func sessionsListForkShellCommand(
        arguments: [String],
        agent: String,
        record: ClaudeHookSessionRecord,
        launchCommand: AgentHookLaunchCommandRecord?
    ) -> String {
        var commandParts: [String] = []
        let selectedEnvironment = AgentLaunchEnvironmentPolicy.selectedEnvironment(
            from: launchCommand?.environment ?? [:],
            kind: agent
        )
        if !selectedEnvironment.isEmpty {
            commandParts.append("env")
            for key in selectedEnvironment.keys.sorted() {
                guard let value = selectedEnvironment[key] else { continue }
                commandParts.append("\(key)=\(value)")
            }
        }
        commandParts.append(contentsOf: arguments)

        let workingDirectory = sessionsListNormalized(launchCommand?.workingDirectory ?? record.cwd)
        let sanitizedCommandParts = AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
            from: commandParts,
            workingDirectory: workingDirectory
        )
        let shellCommand = agent == "codex"
            ? AgentResumeArgv.renderedPortableCodexResumeShellCommand(
                parts: sanitizedCommandParts,
                quote: sessionsListShellSingleQuoted
            )
            : agent == "claude"
            ? AgentResumeArgv.renderedPortableClaudeResumeShellCommand(
                parts: sanitizedCommandParts,
                quote: sessionsListShellSingleQuoted
            )
            : sanitizedCommandParts.map(sessionsListShellSingleQuoted).joined(separator: " ")
        return sessionsListWorkingDirectoryPrefixed(shellCommand, workingDirectory: workingDirectory)
    }

    func sessionsListTrustedLaunchCommand(
        agent: String,
        record: ClaudeHookSessionRecord
    ) -> AgentHookLaunchCommandRecord? {
        guard let launchCommand = record.launchCommand,
              AgentLaunchCaptureTrust.launcherDescribesKind(launchCommand.launcher, kind: agent),
              !AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(launchCommand.arguments) else {
            return nil
        }
        return launchCommand
    }

    func sessionsListWorkingDirectoryPrefixed(_ command: String, workingDirectory: String?) -> String {
        guard let workingDirectory else { return command }
        let quoted = sessionsListShellSingleQuoted(workingDirectory)
        return "{ cd -- \(quoted) 2>/dev/null || [ ! -d \(quoted) ]; } && \(command)"
    }

    func sessionsListShellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
