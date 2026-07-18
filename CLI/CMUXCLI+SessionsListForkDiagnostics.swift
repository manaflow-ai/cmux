import Foundation
import CMUXAgentLaunch
import Darwin


extension CMUXCLI {
    func sessionsListForkDiagnostics(
        agent: String,
        record: ClaudeHookSessionRecord,
        claudeTranscriptLookup: SessionsListClaudeTranscriptLookupCache
    ) -> [String: Any] {
        // Keep diagnostics bound to the exact hook identity used by the list
        // projection. Transcript lookup only verifies that identity.
        let diagnosticRecord = record
        let storedPIDExists = sessionsListStoredPIDExists(diagnosticRecord.pid)
        let hookRecordRestorable = agentHookRecordIsRestorable(
            agent: agent,
            record: diagnosticRecord,
            claudeTranscriptLookup: claudeTranscriptLookup
        )
        let trustedLaunchCommand = sessionsListTrustedLaunchCommand(agent: agent, record: diagnosticRecord)
        let forkArguments = hookRecordRestorable ? sessionsListForkArguments(
            agent: agent,
            record: diagnosticRecord,
            launchCommand: trustedLaunchCommand
        ) : nil
        let forkCommandAvailable = forkArguments != nil
        let support = sessionsListForkSupport(
            agent: agent,
            record: diagnosticRecord,
            launchCommand: trustedLaunchCommand,
            hookRecordRestorable: hookRecordRestorable,
            forkCommandAvailable: forkCommandAvailable
        )
        let forkSupported = support.supported
        let forkStartupInputAvailable = forkArguments.map {
            sessionsListForkStartupInputAvailable(
                arguments: $0,
                agent: agent,
                record: diagnosticRecord,
                launchCommand: trustedLaunchCommand
            )
        } ?? false
        let unavailableReason: String
        if forkSupported {
            unavailableReason = "available"
        } else if !hookRecordRestorable {
            unavailableReason = "record_marked_non_restorable"
        } else if !forkCommandAvailable {
            unavailableReason = "agent_has_no_fork_command"
        } else {
            unavailableReason = support.unavailableReason
        }

        var diagnostics: [String: Any] = [
            "fork_command_available": forkCommandAvailable,
            "fork_supported": forkSupported,
            "fork_unavailable_reason": unavailableReason,
            "fork_startup_input_available": forkStartupInputAvailable,
            "hook_record_restorable": hookRecordRestorable,
            "stale_pid_blocks_restore_in_0_64_17": sessionsListStalePIDBlocksRestoreIn06417(
                agent: agent,
                record: diagnosticRecord,
                hookRecordRestorable: hookRecordRestorable
            ),
        ]
        if let pid = diagnosticRecord.pid,
           let process = sessionsListProcessIdentity(for: pid) {
            diagnostics["stored_pid_arguments"] = process.arguments
        }
        diagnostics["stored_pid_exists"] = storedPIDExists ?? NSNull()
        return diagnostics
    }

    private func sessionsListStalePIDBlocksRestoreIn06417(
        agent: String,
        record: ClaudeHookSessionRecord,
        hookRecordRestorable: Bool
    ) -> Bool {
        guard hookRecordRestorable, let pid = record.pid else { return false }
        return !sessionsListStoredPIDStillMatchesLaunch(agent: agent, record: record, pid: pid)
    }

    private func sessionsListStoredPIDStillMatchesLaunch(
        agent: String,
        record: ClaudeHookSessionRecord,
        pid: Int
    ) -> Bool {
        guard let process = sessionsListProcessIdentity(for: pid),
              sessionsListProcessStartTimeMatchesRecord(process.startTime, record: record) else {
            return false
        }
        let literalCaseInsensitive: String.CompareOptions = [.caseInsensitive, .literal]
        guard let recordedExecutable = sessionsListRecordedExecutableBasename(record),
              let liveExecutable = sessionsListProcessExecutableBasename(process) else {
            return true
        }
        if liveExecutable.compare(recordedExecutable, options: literalCaseInsensitive) == .orderedSame {
            return true
        }
        guard agent == "claude" else { return false }
        let liveBase = liveExecutable.lowercased()
        guard liveBase == "node" || liveBase == "bun" else { return false }
        return process.arguments.dropFirst().contains { argument in
            let lowered = argument.lowercased()
            return sessionsListExecutableBasename(argument).compare("claude", options: literalCaseInsensitive) == .orderedSame
                || lowered.contains("/.claude/")
                || lowered.contains("/claude/versions/")
        }
    }

    private func sessionsListProcessExecutableBasename(_ process: SessionsListProcessIdentity) -> String? {
        if let executablePath = sessionsListNormalized(process.executablePath) {
            return sessionsListExecutableBasename(executablePath)
        }
        return process.arguments.first.map(sessionsListExecutableBasename)
    }

    private func sessionsListRecordedExecutableBasename(_ record: ClaudeHookSessionRecord) -> String? {
        let executable = sessionsListNormalized(record.launchCommand?.executablePath)
            ?? record.launchCommand?.arguments.first.flatMap(sessionsListNormalized)
        return executable.map(sessionsListExecutableBasename)
    }

    private func sessionsListExecutableBasename(_ value: String) -> String {
        (value as NSString).lastPathComponent
    }

    /// One restore-evidence predicate shared by list visibility, tree
    /// visibility, and fork diagnostics. A rejected launch capture is an
    /// explicit trust failure and cannot be rescued by a legacy nil flag.
    func agentHookRecordIsRestorable(
        agent: String,
        record: ClaudeHookSessionRecord,
        claudeTranscriptLookup: SessionsListClaudeTranscriptLookupCache
    ) -> Bool {
        guard record.restoreAuthority != false,
              sessionsListNormalized(record.launchCommand?.source)?.lowercased() != "rejected" else {
            return false
        }
        if agent == "gemini" {
            guard record.isRestorable != false,
                  let transcriptPath = sessionsListNormalized(record.transcriptPath) else {
                return false
            }
            return sessionsListRegularNonEmptyFileExists(
                atPath: (transcriptPath as NSString).expandingTildeInPath
            )
        }
        guard agent == "claude" else {
            guard record.isRestorable != false else { return false }
            return agentHookSessionHasDurableResumeEvidence(
                kind: agent,
                launchCommand: record.launchCommand,
                transcriptPath: record.transcriptPath
            )
        }
        guard sessionsListClaudeSessionIdIsSafeFilename(record.sessionId) else {
            return false
        }
        if let transcriptPath = sessionsListNormalized(record.transcriptPath) {
            let expandedTranscriptPath = (transcriptPath as NSString).expandingTildeInPath
            guard sessionsListClaudeTranscriptPath(
                expandedTranscriptPath,
                matchesSessionId: record.sessionId
            ) else {
                return false
            }
            if sessionsListRegularNonEmptyFileExists(atPath: expandedTranscriptPath) {
                return true
            }
        }
        return sessionsListClaudeTranscriptExists(record: record, lookup: claudeTranscriptLookup)
    }

    func sessionsListRegularNonEmptyFileExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    private func sessionsListClaudeTranscriptExists(
        record: ClaudeHookSessionRecord,
        lookup: SessionsListClaudeTranscriptLookupCache
    ) -> Bool {
        guard sessionsListClaudeSessionIdIsSafeFilename(record.sessionId) else {
            return false
        }
        let roots = lookup.configRoots(record: record)
        guard !roots.isEmpty else { return false }

        var seenProjectDirectories: Set<String> = []
        let candidates = [
            sessionsListNormalized(record.launchCommand?.workingDirectory),
            sessionsListNormalized(record.cwd),
        ].compactMap { $0 }
        for cwd in candidates {
            let projectDirectory = sessionsListEncodeClaudeProjectDir(cwd)
            guard seenProjectDirectories.insert(projectDirectory).inserted else { continue }
            for root in roots {
                if lookup.transcriptPath(
                    configRoot: root,
                    projectDirName: projectDirectory,
                    sessionId: record.sessionId
                ) != nil {
                    return true
                }
            }
        }
        return false
    }

    func sessionsListClaudeSessionIdIsSafeFilename(_ sessionId: String) -> Bool {
        sessionId.range(of: #"[\\/]"#, options: .regularExpression) == nil
            && !sessionId.isEmpty
            && sessionId != "."
            && sessionId != ".."
            && sessionId.trimmingCharacters(in: .whitespacesAndNewlines) == sessionId
            && sessionId.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private func sessionsListClaudeTranscriptPath(_ path: String, matchesSessionId sessionId: String) -> Bool {
        (path as NSString).lastPathComponent == "\(sessionId).jsonl"
    }

    func sessionsListEncodeClaudeProjectDir(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    func sessionsListDirectoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func sessionsListForkSupport(
        agent: String,
        record: ClaudeHookSessionRecord,
        launchCommand: AgentHookLaunchCommandRecord?,
        hookRecordRestorable: Bool,
        forkCommandAvailable: Bool
    ) -> (supported: Bool, unavailableReason: String) {
        guard hookRecordRestorable else {
            return (false, "record_marked_non_restorable")
        }
        guard forkCommandAvailable else {
            return (false, "agent_has_no_fork_command")
        }
        if let piFamilyAgent = sessionsListPiFamilyAgent(agent: agent, launchCommand: launchCommand) {
            return (false, "\(piFamilyAgent)_version_unverified")
        }
        guard agent == "opencode" else {
            return (true, "available")
        }
        if launchCommand?.launcher == "omo" {
            return (true, "available")
        }
        if sessionsListOpenCodeLooksRemoteLike(record, launchCommand: launchCommand) {
            return (true, "available")
        }
        if let executable = sessionsListOpenCodeProbeExecutable(launchCommand),
           executable.hasPrefix("/"),
           !FileManager.default.isExecutableFile(atPath: executable) {
            return (false, "opencode_executable_missing")
        }
        return (false, "opencode_version_unverified")
    }

    private func sessionsListPiFamilyAgent(
        agent: String,
        launchCommand: AgentHookLaunchCommandRecord?
    ) -> String? {
        let normalizedAgent = agent.lowercased()
        if normalizedAgent == "pi" || normalizedAgent == "omp" {
            return normalizedAgent
        }
        let launcher = sessionsListNormalized(launchCommand?.launcher)?.lowercased()
        if launcher == "pi" || launcher == "omp" {
            return launcher
        }
        if !normalizedAgent.isEmpty || launcher != nil {
            return nil
        }
        let capturedExecutable = [
            launchCommand?.executablePath,
            launchCommand?.arguments.first,
        ]
            .compactMap { $0.map(sessionsListExecutableBasename) }
            .map { $0.lowercased() }
            .first { $0 == "pi" || $0 == "omp" }
        if let capturedExecutable {
            return capturedExecutable
        }
        return nil
    }

    private func sessionsListOpenCodeLooksRemoteLike(
        _ record: ClaudeHookSessionRecord,
        launchCommand: AgentHookLaunchCommandRecord?
    ) -> Bool {
        guard let workingDirectory = sessionsListNormalized(
            launchCommand?.workingDirectory ?? record.cwd
        ) else {
            return false
        }
        var isDirectory: ObjCBool = false
        return !FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory)
            || !isDirectory.boolValue
    }

    private func sessionsListOpenCodeProbeExecutable(_ launchCommand: AgentHookLaunchCommandRecord?) -> String? {
        if let executablePath = sessionsListNormalized(launchCommand?.executablePath) {
            return executablePath
        }
        return launchCommand?.arguments.first.flatMap(sessionsListNormalized)
    }

    private func sessionsListForkArguments(
        agent: String,
        record: ClaudeHookSessionRecord,
        launchCommand: AgentHookLaunchCommandRecord?
    ) -> [String]? {
        let normalizedSessionId = record.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionId.isEmpty else { return nil }
        let forkArgv = AgentForkArgv()
        switch forkArgv.launcherResolution(
            launcher: launchCommand?.launcher,
            sessionId: normalizedSessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? []
        ) {
        case .resolved(let argv):
            return argv
        case .passthrough:
            return forkArgv.builtInKind(
                kind: agent,
                sessionId: normalizedSessionId,
                executablePath: launchCommand?.executablePath,
                arguments: launchCommand?.arguments ?? []
            )
        }
    }

    private func sessionsListStoredPIDExists(_ pid: Int?) -> Bool? {
        guard let pid, pid > 0 else { return nil }
        guard let processID = pid_t(exactly: pid) else { return nil }
        errno = 0
        if Darwin.kill(processID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}
