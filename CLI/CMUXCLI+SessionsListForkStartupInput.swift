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
        let environmentParts = sessionsListLaunchEnvironmentParts(
            agent: agent,
            environment: launchCommand?.environment
        )
        if !environmentParts.isEmpty {
            commandParts.append("env")
            commandParts.append(contentsOf: environmentParts)
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
        return "cd -- \(quoted) 2>/dev/null || [ ! -d \(quoted) ] && \(command)"
    }

    func sessionsListShellSingleQuoted(_ value: String) -> String {
        if value.utf8.contains(where: { $0 >= 0x80 }) {
            return sessionsListASCIIPrintfCommandSubstitution(for: value)
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func sessionsListLaunchEnvironmentParts(
        agent: String,
        environment: [String: String]?
    ) -> [String] {
        guard let environment, !environment.isEmpty else { return [] }
        let selectedEnvironment = AgentLaunchEnvironmentPolicy().selectedEnvironment(from: environment, kind: agent)
        var environmentParts: [String] = []
        var preservedClaudeKeys: [String] = []
        for key in selectedEnvironment.keys.sorted() {
            guard let value = selectedEnvironment[key] else { continue }
            environmentParts.append("\(key)=\(value)")
            if agent == "claude", sessionsListClaudeAuthSelectionEnvironmentKeys.contains(key) {
                preservedClaudeKeys.append(key)
            }
        }
        if !preservedClaudeKeys.isEmpty {
            environmentParts.append("CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1")
            environmentParts.append("CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=\(preservedClaudeKeys.joined(separator: ","))")
        }
        return environmentParts
    }

    private var sessionsListClaudeAuthSelectionEnvironmentKeys: Set<String> {
        [
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_MODEL",
            "ANTHROPIC_SMALL_FAST_MODEL",
            "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX",
            "CLAUDE_CONFIG_DIR",
        ]
    }

    private func sessionsListASCIIPrintfCommandSubstitution(for value: String) -> String {
        let octalBytes = value.utf8
            .map { String(format: #"\%03o"#, Int($0)) }
            .joined()
        return #""$(printf '"# + octalBytes + #"')""#
    }
}
