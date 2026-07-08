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

        if executableCandidates.contains(where: { executable in
            CachedAgentProcessIdentityValidator.liveClaudeProcessExecutableMatches(
                kind: .claude,
                liveExecutable: executableBasename(executable),
                arguments: arguments
            )
        }) {
            return true
        }

        // `CMUX_AGENT_LAUNCH_KIND` is cmux's own launch token, but descendants of a
        // claude launch inherit it, so ambient environment alone is not process
        // identity. Trust it only when this process runs the executable the launcher
        // recorded (covers custom claude binaries whose basename is not "claude"),
        // never for a child that merely inherited the launch environment.
        guard normalized(environment["CMUX_AGENT_LAUNCH_KIND"])?.compare(
            "claude",
            options: [.caseInsensitive, .literal]
        ) == .orderedSame,
              let launchExecutable = normalized(environment["CMUX_AGENT_LAUNCH_EXECUTABLE"]) else {
            return false
        }
        let launchBasename = executableBasename(launchExecutable)
        let launchCandidates = executableCandidates + [arguments.dropFirst().first].compactMap(normalized)
        return launchCandidates.contains { candidate in
            executableBasename(candidate).compare(launchBasename, options: [.caseInsensitive, .literal]) == .orderedSame
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
            arguments: arguments,
            environment: environment
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
        arguments: [String],
        environment: [String: String]
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
        // Custom claude binaries (accepted via the launch-executable identity check in
        // processLooksLikeClaude) are an executable boundary too; without this their
        // sanitizer-preserved flags (e.g. --model) would be dropped from the snapshot.
        if let launchExecutable = normalized(environment["CMUX_AGENT_LAUNCH_EXECUTABLE"]) {
            let launchBasename = executableBasename(launchExecutable)
            if executableBasename(arguments[0]).compare(launchBasename, options: [.caseInsensitive, .literal]) == .orderedSame {
                return Array(arguments.dropFirst())
            }
            if let processPath = normalized(processPath),
               executableBasename(processPath).compare(launchBasename, options: [.caseInsensitive, .literal]) == .orderedSame {
                return arguments[0].hasPrefix("-") ? arguments : Array(arguments.dropFirst())
            }
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

    /// A pane's own hook record overrides the fork-parent fallback only when it was
    /// written during the detected fork process's lifetime (the fork minting its id at
    /// first prompt); an older record belongs to a previous session in a reused pane.
    /// Unknown start times keep the hook record authoritative (pre-fallback behavior).
    static func hookCandidateRepresentsDetectedProcess(
        _ candidate: Entry,
        detected: ProcessDetectedSnapshotEntry,
        processIdentityProvider: (Int) -> AgentPIDProcessIdentity?
    ) -> Bool {
        // Full subsecond start time: comparing whole seconds would let a record updated
        // at 15.1s survive a fork process started at 15.9s within the same second.
        let startTimes = detected.agentProcessIDs.compactMap { pid -> TimeInterval? in
            guard let identity = processIdentityProvider(pid) else { return nil }
            return TimeInterval(identity.startSeconds) + TimeInterval(identity.startMicroseconds) / 1_000_000
        }
        guard let earliestStart = startTimes.min() else { return true }
        return candidate.updatedAt >= earliestStart
    }

    /// A `.forkParentFallback` detection is claude-kind identity inferred from a live
    /// process, so it may fill an empty pane or refine a claude pane, but it must never
    /// displace a hook-backed entry of another agent kind (a nested
    /// `claude --resume <id> --fork-session` child inside a codex/opencode/custom pane
    /// inherits that pane's cmux scope).
    static func forkParentFallbackMustYield(toExisting existing: Entry?) -> Bool {
        guard let existing else { return false }
        return existing.snapshot.kind != .claude
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
        // Mirrors `claudeLaunchArgumentsContainForkSession` in CLI/cmux.swift so the
        // scanner and the hook CLI agree on which launches count as forks.
        contains { argument in
            if argument == "--fork-session" {
                return true
            }
            let prefix = "--fork-session="
            guard argument.hasPrefix(prefix) else { return false }
            let value = String(argument.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return !["false", "0", "no", "off"].contains(value)
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
