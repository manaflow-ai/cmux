import Foundation
import CMUXAgentLaunch

extension RestorableAgentSessionIndex {
    /// Fallback identity only: the caller merges these with `{ existing, _ in existing }`
    /// so a claude fork process never displaces an explicit same-pane detection
    /// (e.g. an OpenCode pane hosting a nested claude fork process).
    static func processDetectedClaudeForkFallbackSnapshots(
        processSnapshot: CmuxTopProcessSnapshot,
        capturedAt: TimeInterval,
        scopedProcessIDsByPanelKey: [PanelKey: Set<Int>],
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?
    ) -> [PanelKey: ProcessDetectedSnapshotEntry] {
        var resolved: [PanelKey: ProcessDetectedSnapshotEntry] = [:]

        for process in processSnapshot.cmuxScopedProcesses() {
            guard let workspaceId = process.cmuxWorkspaceID,
                  let panelId = process.cmuxSurfaceID,
                  let processArguments = processArgumentsProvider(process.pid) else {
                continue
            }

            let environment = processArguments.environment
            let arguments = processArguments.arguments
            guard processLooksLikeClaude(
                processName: process.name,
                processPath: process.path,
                arguments: arguments,
                environment: environment
            ),
                  let parentSessionId = arguments.claudeForkFallbackParentSessionId,
                  let launchCommand = claudeForkFallbackLaunchCommand(
                      processName: process.name,
                      processPath: process.path,
                      arguments: arguments,
                      environment: environment
                  ) else {
                continue
            }

            let cwd = normalized(environment["CMUX_AGENT_LAUNCH_CWD"] ?? environment["PWD"])
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            let snapshot = SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: parentSessionId,
                workingDirectory: cwd,
                launchCommand: AgentLaunchCommandSnapshot(
                    processDetectedLauncher: "claude",
                    executablePath: launchCommand.executablePath,
                    arguments: launchCommand.arguments,
                    workingDirectory: cwd,
                    environment: environment
                )
            )
            resolved[key] = (
                snapshot: snapshot,
                updatedAt: capturedAt,
                processIDs: scopedProcessIDsByPanelKey[key] ?? [],
                agentProcessIDs: [process.pid],
                sessionIDSource: .forkParentFallback
            )
        }

        return resolved
    }

    private static func processLooksLikeClaude(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        if normalized(environment["CMUX_AGENT_LAUNCH_KIND"])?.compare(
            "claude",
            options: [.caseInsensitive, .literal]
        ) == .orderedSame {
            return true
        }

        let executableCandidates = [
            arguments.first,
            processPath,
            processName,
        ].compactMap(normalized)
        if executableCandidates.contains(where: { executableBasename($0).compare(
            "claude",
            options: [.caseInsensitive, .literal]
        ) == .orderedSame }) {
            return true
        }

        return executableCandidates.contains { executable in
            CachedAgentProcessIdentityValidator.liveClaudeProcessExecutableMatches(
                kind: .claude,
                liveExecutable: executableBasename(executable),
                arguments: arguments
            )
        }
    }

    private static func claudeForkFallbackLaunchCommand(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String]
    ) -> (executablePath: String, arguments: [String])? {
        let executablePath = claudeExecutablePath(
            processName: processName,
            processPath: processPath,
            arguments: arguments,
            environment: environment
        )
        let launchTail = claudeLaunchTail(
            processName: processName,
            processPath: processPath,
            arguments: arguments
        )
        guard let sanitized = AgentLaunchSanitizer.sanitizedLaunchArguments(
            [executablePath] + launchTail,
            launcher: "claude",
            fallbackKind: "claude"
        ) else {
            return nil
        }
        return (executablePath: executablePath, arguments: sanitized)
    }

    private static func claudeExecutablePath(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String]
    ) -> String {
        if let argumentExecutable = normalized(arguments.first),
           executableBasename(argumentExecutable).compare("claude", options: [.caseInsensitive, .literal]) == .orderedSame {
            return argumentExecutable
        }
        if let processPath = normalized(processPath),
           executableBasename(processPath).compare("claude", options: [.caseInsensitive, .literal]) == .orderedSame {
            return processPath
        }
        if let launchExecutable = normalized(environment["CMUX_AGENT_LAUNCH_EXECUTABLE"]),
           executableBasename(launchExecutable).compare("claude", options: [.caseInsensitive, .literal]) == .orderedSame {
            return launchExecutable
        }
        if executableBasename(processName).compare("claude", options: [.caseInsensitive, .literal]) == .orderedSame {
            return normalized(arguments.first) ?? processName
        }
        if let nestedClaude = arguments.dropFirst().first(where: argumentLooksLikeNestedClaudeEntrypoint) {
            return executableBasename(nestedClaude).compare("claude", options: [.caseInsensitive, .literal]) == .orderedSame
                ? nestedClaude
                : "claude"
        }
        return "claude"
    }

    private static func claudeLaunchTail(
        processName: String,
        processPath: String?,
        arguments: [String]
    ) -> [String] {
        guard !arguments.isEmpty else { return [] }
        if executableBasename(arguments[0]).compare("claude", options: [.caseInsensitive, .literal]) == .orderedSame {
            return Array(arguments.dropFirst())
        }
        if let processPath = normalized(processPath),
           executableBasename(processPath).compare("claude", options: [.caseInsensitive, .literal]) == .orderedSame {
            return arguments[0].hasPrefix("-") ? arguments : Array(arguments.dropFirst())
        }
        if executableBasename(processName).compare("claude", options: [.caseInsensitive, .literal]) == .orderedSame {
            return arguments[0].hasPrefix("-") ? arguments : Array(arguments.dropFirst())
        }
        guard let entrypointIndex = arguments.dropFirst().firstIndex(where: argumentLooksLikeNestedClaudeEntrypoint) else {
            return []
        }
        return Array(arguments.dropFirst(entrypointIndex + 1))
    }

    private static func argumentLooksLikeNestedClaudeEntrypoint(_ argument: String) -> Bool {
        let lowered = argument.lowercased()
        return executableBasename(argument).compare("claude", options: [.caseInsensitive, .literal]) == .orderedSame
            || lowered.contains("/.claude/")
            || lowered.contains("/claude/versions/")
    }

    private static func executableBasename(_ value: String) -> String {
        (value as NSString).lastPathComponent
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private extension Array where Element == String {
    var claudeForkFallbackParentSessionId: String? {
        guard hasClaudeForkSessionFlag,
              !hasClaudeSessionIDOption else {
            return nil
        }
        return nonOptionValue(afterOption: "--resume") ?? nonOptionValue(afterOption: "-r")
    }

    private var hasClaudeForkSessionFlag: Bool {
        contains { argument in
            if argument == "--fork-session" {
                return true
            }
            let prefix = "--fork-session="
            guard argument.hasPrefix(prefix) else { return false }
            let value = String(argument.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return false }
            return !["0", "false", "no"].contains(value.lowercased())
        }
    }

    private var hasClaudeSessionIDOption: Bool {
        contains { argument in
            argument == "--session-id" || argument.hasPrefix("--session-id=")
        }
    }

    private func nonOptionValue(afterOption option: String) -> String? {
        for index in indices {
            let argument = self[index]
            if argument == option {
                let nextIndex = self.index(after: index)
                guard nextIndex < endIndex else { return nil }
                return normalizedNonOptionValue(self[nextIndex])
            }
            let prefix = option + "="
            if argument.hasPrefix(prefix) {
                return normalizedNonOptionValue(String(argument.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private func normalizedNonOptionValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("-"),
              UUID(uuidString: trimmed) != nil else {
            return nil
        }
        return trimmed
    }
}
