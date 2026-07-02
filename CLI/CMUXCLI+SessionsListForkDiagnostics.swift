import Foundation
import CMUXAgentLaunch
import Darwin

final class SessionsListClaudeTranscriptLookupCache {
    private let homeDirectory: String
    private var defaultRoots: [String]?
    private var projectDirsByConfigRoot: [String: [String]] = [:]
    private var transcriptPathByProjectRootAndSession: [String: String] = [:]
    private var missingTranscriptPathByProjectRootAndSession: Set<String> = []
    private var transcriptPathByConfigRootAndSession: [String: String] = [:]
    private var missingTranscriptPathByConfigRootAndSession: Set<String> = []

    init(homeDirectory: String) {
        self.homeDirectory = homeDirectory
    }

    func configRoots(record: ClaudeHookSessionRecord) -> [String] {
        if let configured = normalized(record.launchCommand?.environment?["CLAUDE_CONFIG_DIR"]) {
            return [
                ClaudeConfigDirectoryPath.preferredPath(
                    expandedPath(configured),
                    fileManager: .default,
                    homeDirectory: homeDirectory
                ),
            ]
        }

        if let defaultRoots { return defaultRoots }

        var roots: [String] = []
        var seen: Set<String> = []
        func appendRoot(_ path: String) {
            let standardized = (path as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { return }
            roots.append(standardized)
        }

        let accountRoot = (homeDirectory as NSString).appendingPathComponent(".codex-accounts/claude")
        if directoryExists(atPath: accountRoot),
           let accountDirs = try? FileManager.default.contentsOfDirectory(atPath: accountRoot) {
            for accountDir in accountDirs.sorted() {
                appendRoot((accountRoot as NSString).appendingPathComponent(accountDir))
            }
        }
        appendRoot((homeDirectory as NSString).appendingPathComponent(".claude"))
        appendRoot(
            ClaudeConfigDirectoryPath.preferredPath(
                (homeDirectory as NSString).appendingPathComponent(".subrouter/codex/claude"),
                fileManager: .default,
                homeDirectory: homeDirectory
            )
        )

        defaultRoots = roots
        return roots
    }

    func transcriptPath(configRoot: String, projectDirName: String, sessionId: String) -> String? {
        let standardizedRoot = (configRoot as NSString).standardizingPath
        let projectsRoot = (standardizedRoot as NSString).appendingPathComponent("projects")
        let projectRoot = ((projectsRoot as NSString).appendingPathComponent(projectDirName) as NSString)
            .standardizingPath
        let key = cacheKey(projectRoot, sessionId)
        if let cached = transcriptPathByProjectRootAndSession[key] { return cached }
        if missingTranscriptPathByProjectRootAndSession.contains(key) { return nil }

        let path = transcriptPath(inProjectRoot: projectRoot, sessionId: sessionId)
        if let path {
            transcriptPathByProjectRootAndSession[key] = path
        } else {
            missingTranscriptPathByProjectRootAndSession.insert(key)
        }
        return path
    }

    func transcriptPathInAnyProject(configRoot: String, sessionId: String) -> String? {
        let standardizedRoot = (configRoot as NSString).standardizingPath
        let key = cacheKey(standardizedRoot, sessionId)
        if let cached = transcriptPathByConfigRootAndSession[key] { return cached }
        if missingTranscriptPathByConfigRootAndSession.contains(key) { return nil }

        for projectDir in projectDirs(configRoot: standardizedRoot) {
            if let path = transcriptPath(
                configRoot: standardizedRoot,
                projectDirName: projectDir,
                sessionId: sessionId
            ) {
                transcriptPathByConfigRootAndSession[key] = path
                return path
            }
        }
        missingTranscriptPathByConfigRootAndSession.insert(key)
        return nil
    }

    func projectDirs(configRoot: String) -> [String] {
        let standardizedRoot = (configRoot as NSString).standardizingPath
        if let cached = projectDirsByConfigRoot[standardizedRoot] { return cached }
        let projectsRoot = (standardizedRoot as NSString).appendingPathComponent("projects")
        guard directoryExists(atPath: projectsRoot),
              let projectDirs = try? FileManager.default.contentsOfDirectory(atPath: projectsRoot) else {
            projectDirsByConfigRoot[standardizedRoot] = []
            return []
        }
        projectDirsByConfigRoot[standardizedRoot] = projectDirs
        return projectDirs
    }

    private func transcriptPath(inProjectRoot projectRoot: String, sessionId: String) -> String? {
        guard directoryExists(atPath: projectRoot) else { return nil }
        let directPath = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
        if regularNonEmptyFileExists(atPath: directPath) { return directPath }

        let nestedMessagesPath = (((projectRoot as NSString)
            .appendingPathComponent(sessionId) as NSString)
            .appendingPathComponent("messages") as NSString)
            .appendingPathComponent("\(sessionId).jsonl")
        if regularNonEmptyFileExists(atPath: nestedMessagesPath) { return nestedMessagesPath }
        return nil
    }

    private func regularNonEmptyFileExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    private func directoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func expandedPath(_ value: String) -> String {
        (value as NSString).expandingTildeInPath
    }

    private func cacheKey(_ prefix: String, _ sessionId: String) -> String {
        prefix + "\u{0}" + sessionId
    }
}

extension CMUXCLI {
    func sessionsListForkDiagnostics(
        agent: String,
        record: ClaudeHookSessionRecord,
        claudeTranscriptLookup: SessionsListClaudeTranscriptLookupCache
    ) -> [String: Any] {
        let diagnosticRecord = agent == "claude"
            ? sessionsListResolvedClaudeWorkflowRecord(record, lookup: claudeTranscriptLookup)
            : record
        let storedPIDExists = sessionsListStoredPIDExists(diagnosticRecord.pid)
        let hookRecordRestorable = sessionsListHookRecordRestorable(
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

    private func sessionsListHookRecordRestorable(
        agent: String,
        record: ClaudeHookSessionRecord,
        claudeTranscriptLookup: SessionsListClaudeTranscriptLookupCache
    ) -> Bool {
        guard agent == "claude" else {
            return record.isRestorable != false
        }
        if let transcriptPath = sessionsListNormalized(record.transcriptPath),
           sessionsListRegularNonEmptyFileExists(
               atPath: (transcriptPath as NSString).expandingTildeInPath
           ) {
            return true
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

        let cwd = sessionsListNormalized(record.cwd) ?? sessionsListNormalized(record.launchCommand?.workingDirectory)
        for root in roots {
            if let cwd,
               lookup.transcriptPath(
                   configRoot: root,
                   projectDirName: sessionsListEncodeClaudeProjectDir(cwd),
                   sessionId: record.sessionId
               ) != nil {
                return true
            }
            if lookup.transcriptPathInAnyProject(configRoot: root, sessionId: record.sessionId) != nil {
                return true
            }
        }
        return false
    }

    func sessionsListClaudeSessionIdIsSafeFilename(_ sessionId: String) -> Bool {
        sessionId.range(of: #"[\\/]"#, options: .regularExpression) == nil
            && !sessionId.isEmpty
            && sessionId != "."
            && sessionId != ".."
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
