import Foundation
import CMUXAgentLaunch
import Darwin

final class SessionsListClaudeTranscriptLookupCache {
    private struct ConfigurationIndex {
        var projectRootsByWorkflowSession: [String: [String]]
        var transcriptPathBySession: [String: String]
    }

    private let homeDirectory: String
    private let fileManager: FileManager
    private var defaultRoots: [String]?
    private var projectDirsByConfigRoot: [String: [String]] = [:]
    private var transcriptPathByProjectRootAndSession: [String: String] = [:]
    private var missingTranscriptPathByProjectRootAndSession: Set<String> = []
    private var transcriptPathByConfigRootAndSession: [String: String] = [:]
    private var missingTranscriptPathByConfigRootAndSession: Set<String> = []
    private var configurationIndexByRoot: [String: ConfigurationIndex] = [:]
    private var workflowTranscriptsByProjectRoot: [String: [(sessionId: String, path: String)]] = [:]

    init(homeDirectory: String, fileManager: FileManager = .default) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    func configRoots(record: ClaudeHookSessionRecord) -> [String] {
        if let configured = normalized(record.launchCommand?.environment?["CLAUDE_CONFIG_DIR"]) {
            return [
                ClaudeConfigDirectoryPath.preferredPath(
                    expandedPath(configured),
                    fileManager: fileManager,
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
           let accountDirs = try? fileManager.contentsOfDirectory(atPath: accountRoot) {
            for accountDir in accountDirs.sorted() {
                appendRoot((accountRoot as NSString).appendingPathComponent(accountDir))
            }
        }
        appendRoot((homeDirectory as NSString).appendingPathComponent(".claude"))
        appendRoot(
            ClaudeConfigDirectoryPath.preferredPath(
                (homeDirectory as NSString).appendingPathComponent(".subrouter/codex/claude"),
                fileManager: fileManager,
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

        if let path = configurationIndex(configRoot: standardizedRoot)
            .transcriptPathBySession[sessionId] {
            transcriptPathByConfigRootAndSession[key] = path
            return path
        }
        missingTranscriptPathByConfigRootAndSession.insert(key)
        return nil
    }

    func workflowProjectRoots(configRoot: String, sessionId: String) -> [String] {
        let standardizedRoot = (configRoot as NSString).standardizingPath
        return configurationIndex(configRoot: standardizedRoot)
            .projectRootsByWorkflowSession[sessionId] ?? []
    }

    func singleSiblingTranscript(
        projectRoots: [String],
        excludingSessionId excludedSessionId: String
    ) -> (sessionId: String, path: String)? {
        var match: (sessionId: String, path: String)?
        for projectRoot in projectRoots {
            for candidate in workflowTranscripts(inProjectRoot: projectRoot) {
                guard candidate.sessionId != excludedSessionId else { continue }
                guard match == nil else { return nil }
                match = candidate
            }
        }
        return match
    }

    func projectDirs(configRoot: String) -> [String] {
        let standardizedRoot = (configRoot as NSString).standardizingPath
        if let cached = projectDirsByConfigRoot[standardizedRoot] { return cached }
        let projectsRoot = (standardizedRoot as NSString).appendingPathComponent("projects")
        guard directoryExists(atPath: projectsRoot),
              let projectDirs = try? fileManager.contentsOfDirectory(atPath: projectsRoot) else {
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
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    private func directoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func configurationIndex(configRoot: String) -> ConfigurationIndex {
        let standardizedRoot = (configRoot as NSString).standardizingPath
        if let cached = configurationIndexByRoot[standardizedRoot] { return cached }

        let projectsRoot = (standardizedRoot as NSString).appendingPathComponent("projects")
        var projectRootsByWorkflowSession: [String: [String]] = [:]
        var transcriptPathBySession: [String: String] = [:]
        for projectDir in projectDirs(configRoot: standardizedRoot) {
            let projectRoot = (projectsRoot as NSString).appendingPathComponent(projectDir)
            guard directoryExists(atPath: projectRoot),
                  let children = try? fileManager.contentsOfDirectory(atPath: projectRoot) else {
                continue
            }

            // Preserve the old lookup preference: a direct transcript in one
            // project wins over that project's nested messages transcript.
            for child in children where child.hasSuffix(".jsonl") {
                let sessionId = String(child.dropLast(".jsonl".count))
                guard transcriptPathBySession[sessionId] == nil else { continue }
                let path = (projectRoot as NSString).appendingPathComponent(child)
                if regularNonEmptyFileExists(atPath: path) {
                    transcriptPathBySession[sessionId] = path
                }
            }

            for child in children {
                let childPath = (projectRoot as NSString).appendingPathComponent(child)
                guard directoryExists(atPath: childPath) else { continue }
                projectRootsByWorkflowSession[child, default: []].append(projectRoot)
                guard transcriptPathBySession[child] == nil else { continue }
                let nestedPath = (((childPath as NSString)
                    .appendingPathComponent("messages") as NSString)
                    .appendingPathComponent("\(child).jsonl"))
                if regularNonEmptyFileExists(atPath: nestedPath) {
                    transcriptPathBySession[child] = nestedPath
                }
            }
        }
        let index = ConfigurationIndex(
            projectRootsByWorkflowSession: projectRootsByWorkflowSession,
            transcriptPathBySession: transcriptPathBySession
        )
        configurationIndexByRoot[standardizedRoot] = index
        return index
    }

    private func workflowTranscripts(inProjectRoot projectRoot: String) -> [(sessionId: String, path: String)] {
        let standardizedRoot = (projectRoot as NSString).standardizingPath
        if let cached = workflowTranscriptsByProjectRoot[standardizedRoot] { return cached }
        var matches: [(sessionId: String, path: String)] = []
        collectWorkflowTranscripts(
            inDirectory: standardizedRoot,
            remainingDirectoryDepth: 4,
            matches: &matches
        )
        workflowTranscriptsByProjectRoot[standardizedRoot] = matches
        return matches
    }

    private func collectWorkflowTranscripts(
        inDirectory directory: String,
        remainingDirectoryDepth: Int,
        matches: inout [(sessionId: String, path: String)]
    ) {
        guard directoryExists(atPath: directory),
              let children = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return
        }
        for child in children {
            let childPath = (directory as NSString).appendingPathComponent(child)
            if child.hasSuffix(".jsonl") {
                let sessionId = String(child.dropLast(".jsonl".count))
                guard !sessionId.isEmpty,
                      sessionId != ".",
                      sessionId != "..",
                      sessionId.range(of: #"[\\/]"#, options: .regularExpression) == nil,
                      regularNonEmptyFileExists(atPath: childPath) else {
                    continue
                }
                matches.append((sessionId, childPath))
            } else if remainingDirectoryDepth > 0 {
                collectWorkflowTranscripts(
                    inDirectory: childPath,
                    remainingDirectoryDepth: remainingDirectoryDepth - 1,
                    matches: &matches
                )
            }
        }
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
        // The list projection resolves Claude workflow aliases before it builds
        // the payload. Reuse that record instead of repeating transcript lookup
        // while adding diagnostics for the same row.
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
        guard sessionsListNormalized(record.launchCommand?.source)?.lowercased() != "rejected" else {
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
