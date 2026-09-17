import Foundation
import CMUXAgentLaunch
extension RestorableAgentSessionIndex {
    /// Fallback identity only: the caller merges these with `{ existing, _ in existing }`
    /// so a fork process never displaces an explicit same-pane detection
    /// (e.g. an OpenCode pane hosting a nested claude/codex fork process).
    static func processDetectedForkParentFallbackSnapshots(
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
            guard let fallback = forkParentFallback(
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
                kind: fallback.kind,
                sessionId: fallback.parentSessionId,
                workingDirectory: cwd,
                launchCommand: AgentLaunchCommandSnapshot(
                    processDetectedLauncher: fallback.launcher,
                    executablePath: fallback.launchCommand.executablePath,
                    arguments: fallback.launchCommand.arguments,
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

    private static func forkParentFallback(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String]
    ) -> (
        kind: RestorableAgentKind,
        parentSessionId: String,
        launcher: String,
        launchCommand: (executablePath: String, arguments: [String])
    )? {
        if let wrapperFallback = forkParentFallbackWrapperLaunch(
            processName: processName,
            processPath: processPath,
            arguments: arguments,
            environment: environment
        ) {
            return wrapperFallback
        }
        if processLooksLikeCodex(
            processName: processName,
            processPath: processPath,
            arguments: arguments,
            environment: environment
        ),
           let parentSessionId = arguments.codexForkFallbackParentSessionId,
           let launchCommand = codexForkFallbackLaunchCommand(
                processName: processName,
                processPath: processPath,
                arguments: arguments,
                environment: environment
           ) {
            return (.codex, parentSessionId, "codex", launchCommand)
        }
        return nil
    }

    private static func processLooksLikeCodex(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        let executableCandidates = [arguments.first, processPath, processName].compactMap(normalized)
        if executableCandidates.contains(where: { executableBasename($0).compare("codex", options: [.caseInsensitive, .literal]) == .orderedSame }) {
            return true
        }
        if executableCandidates.contains(where: { executable in
            CachedAgentProcessIdentityValidator.liveCodexProcessExecutableMatches(
                kind: .codex,
                liveExecutable: executableBasename(executable),
                arguments: arguments
            )
        }) {
            return true
        }
        let launchCandidates = executableCandidates + [arguments.dropFirst().first].compactMap(normalized)
        return CachedAgentProcessIdentityValidator.liveProcessMatchesLaunchExecutableEnvironment(
            kind: .codex,
            executableCandidates: launchCandidates,
            environment: environment
        )
    }

    private static func codexForkFallbackLaunchCommand(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String]
    ) -> (executablePath: String, arguments: [String])? {
        let executablePath = codexExecutablePath(
            processName: processName,
            processPath: processPath,
            arguments: arguments,
            environment: environment
        )
        let launchTail = codexLaunchTail(
            processName: processName,
            processPath: processPath,
            arguments: arguments,
            environment: environment
        )
        guard let sanitized = AgentLaunchSanitizer.sanitizedLaunchArguments(
            [executablePath] + launchTail,
            launcher: "codex",
            fallbackKind: "codex-fork-replay"
        ) else {
            return nil
        }
        return (executablePath: executablePath, arguments: sanitized)
    }

    private static func codexExecutablePath(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String]
    ) -> String {
        if let argumentExecutable = normalized(arguments.first),
           executableBasename(argumentExecutable).compare("codex", options: [.caseInsensitive, .literal]) == .orderedSame {
            return argumentExecutable
        }
        if let processPath = normalized(processPath),
           executableBasename(processPath).compare("codex", options: [.caseInsensitive, .literal]) == .orderedSame {
            return processPath
        }
        if let launchExecutable = normalized(environment["CMUX_AGENT_LAUNCH_EXECUTABLE"]),
           executableBasename(launchExecutable).compare("codex", options: [.caseInsensitive, .literal]) == .orderedSame {
            return launchExecutable
        }
        if executableBasename(processName).compare("codex", options: [.caseInsensitive, .literal]) == .orderedSame {
            return normalized(arguments.first) ?? processName
        }
        if let nestedCodex = arguments.dropFirst().first(where: argumentLooksLikeNestedCodexEntrypoint) {
            return executableBasename(nestedCodex).compare("codex", options: [.caseInsensitive, .literal]) == .orderedSame
                ? nestedCodex
                : "codex"
        }
        return "codex"
    }

    private static func codexLaunchTail(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String]
    ) -> [String] {
        guard !arguments.isEmpty else { return [] }
        if executableBasename(arguments[0]).compare("codex", options: [.caseInsensitive, .literal]) == .orderedSame {
            return Array(arguments.dropFirst())
        }
        if let processPath = normalized(processPath),
           executableBasename(processPath).compare("codex", options: [.caseInsensitive, .literal]) == .orderedSame {
            return arguments[0].hasPrefix("-") ? arguments : Array(arguments.dropFirst())
        }
        if executableBasename(processName).compare("codex", options: [.caseInsensitive, .literal]) == .orderedSame {
            return arguments[0].hasPrefix("-") ? arguments : Array(arguments.dropFirst())
        }
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
        guard let entrypointIndex = arguments.dropFirst().firstIndex(where: argumentLooksLikeNestedCodexEntrypoint) else {
            return []
        }
        return Array(arguments.dropFirst(entrypointIndex + 1))
    }

    private static func argumentLooksLikeNestedCodexEntrypoint(_ argument: String) -> Bool {
        let lowered = argument.lowercased()
        return executableBasename(argument).compare("codex", options: [.caseInsensitive, .literal]) == .orderedSame
            || lowered.contains("@openai/codex")
            || lowered.contains("oh-my-codex")
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

    static func environmentLaunchKind(_ environment: [String: String]) -> String? {
        normalized(environment["CMUX_AGENT_LAUNCH_KIND"])?
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
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

    /// A `.forkParentFallback` detection is agent-kind identity inferred from a live
    /// process, so it may fill an empty pane or refine a same-kind pane, but it must never
    /// displace a hook-backed entry of another agent kind (a nested
    /// child process inside another agent pane inherits that pane's cmux scope).
    static func forkParentFallbackMustYield(kind: RestorableAgentKind, toExisting existing: Entry?) -> Bool {
        guard let existing else { return false }
        return existing.snapshot.kind != kind
    }
}

private extension Array where Element == String {
    var codexForkFallbackParentSessionId: String? {
        guard let forkIndex = firstIndex(where: { $0 == "fork" }) else { return nil }
        let sessionIndex = index(after: forkIndex)
        guard sessionIndex < endIndex else { return nil }
        return uuidValue(self[sessionIndex])
    }

    private func uuidValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("-"),
              UUID(uuidString: trimmed) != nil else {
            return nil
        }
        return trimmed
    }
}
