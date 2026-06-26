import Foundation
import CMUXAgentLaunch
import Darwin

extension CMUXCLI {
    func sessionsListForkDiagnostics(
        agent: String,
        record: ClaudeHookSessionRecord,
        homeDirectory: String
    ) -> [String: Any] {
        let storedPIDExists = sessionsListStoredPIDExists(record.pid)
        let hookRecordRestorable = sessionsListHookRecordRestorable(
            agent: agent,
            record: record,
            homeDirectory: homeDirectory
        )
        let forkArguments = hookRecordRestorable ? sessionsListForkArguments(agent: agent, record: record) : nil
        let forkCommandAvailable = forkArguments != nil
        let support = sessionsListForkSupport(
            agent: agent,
            record: record,
            hookRecordRestorable: hookRecordRestorable,
            forkCommandAvailable: forkCommandAvailable
        )
        let forkSupported = support.supported
        let forkStartupInputAvailable = forkArguments.map {
            sessionsListForkStartupInputAvailable(arguments: $0, agent: agent, record: record)
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
            "stale_pid_blocks_restore_in_0_64_17": hookRecordRestorable && record.pid != nil,
        ]
        diagnostics["stored_pid_exists"] = storedPIDExists ?? NSNull()
        return diagnostics
    }

    private func sessionsListHookRecordRestorable(
        agent: String,
        record: ClaudeHookSessionRecord,
        homeDirectory: String
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
        return sessionsListClaudeTranscriptExists(record: record, homeDirectory: homeDirectory)
            || record.isRestorable != false
    }

    private func sessionsListRegularNonEmptyFileExists(atPath path: String) -> Bool {
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
        homeDirectory: String
    ) -> Bool {
        guard sessionsListClaudeSessionIdIsSafeFilename(record.sessionId) else {
            return false
        }
        let roots = sessionsListClaudeConfigRoots(record: record, homeDirectory: homeDirectory)
        guard !roots.isEmpty else { return false }

        let cwd = sessionsListNormalized(record.cwd) ?? sessionsListNormalized(record.launchCommand?.workingDirectory)
        for root in roots {
            if let cwd,
               sessionsListClaudeTranscriptPath(
                   configRoot: root,
                   projectDirName: sessionsListEncodeClaudeProjectDir(cwd),
                   sessionId: record.sessionId
               ) != nil {
                return true
            }
            if sessionsListClaudeTranscriptPathInAnyProject(configRoot: root, sessionId: record.sessionId) != nil {
                return true
            }
        }
        return false
    }

    private func sessionsListClaudeConfigRoots(
        record: ClaudeHookSessionRecord,
        homeDirectory: String
    ) -> [String] {
        if let configured = sessionsListNormalized(record.launchCommand?.environment?["CLAUDE_CONFIG_DIR"]) {
            return [
                ClaudeConfigDirectoryPath.preferredPath(
                    sessionsListExpandedPath(configured),
                    fileManager: .default,
                    homeDirectory: homeDirectory
                ),
            ]
        }

        var roots: [String] = []
        var seen: Set<String> = []
        func appendRoot(_ path: String) {
            let standardized = (path as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { return }
            roots.append(standardized)
        }

        let accountRoot = (homeDirectory as NSString).appendingPathComponent(".codex-accounts/claude")
        if sessionsListDirectoryExists(atPath: accountRoot),
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
        return roots
    }

    private func sessionsListClaudeTranscriptPath(
        configRoot: String,
        projectDirName: String,
        sessionId: String
    ) -> String? {
        let projectsRoot = ((configRoot as NSString).standardizingPath as NSString)
            .appendingPathComponent("projects")
        let projectRoot = ((projectsRoot as NSString).appendingPathComponent(projectDirName) as NSString)
            .standardizingPath
        return sessionsListClaudeTranscriptPath(inProjectRoot: projectRoot, sessionId: sessionId)
    }

    private func sessionsListClaudeTranscriptPathInAnyProject(
        configRoot: String,
        sessionId: String
    ) -> String? {
        let projectsRoot = (((configRoot as NSString).standardizingPath as NSString)
            .appendingPathComponent("projects") as NSString)
            .standardizingPath
        guard sessionsListDirectoryExists(atPath: projectsRoot),
              let projectDirs = try? FileManager.default.contentsOfDirectory(atPath: projectsRoot) else {
            return nil
        }
        for projectDir in projectDirs {
            if let path = sessionsListClaudeTranscriptPath(
                configRoot: configRoot,
                projectDirName: projectDir,
                sessionId: sessionId
            ) {
                return path
            }
        }
        return nil
    }

    private func sessionsListClaudeTranscriptPath(inProjectRoot projectRoot: String, sessionId: String) -> String? {
        guard sessionsListDirectoryExists(atPath: projectRoot) else { return nil }

        let directPath = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
        if sessionsListRegularNonEmptyFileExists(atPath: directPath) {
            return directPath
        }

        let nestedMessagesPath = (((projectRoot as NSString)
            .appendingPathComponent(sessionId) as NSString)
            .appendingPathComponent("messages") as NSString)
            .appendingPathComponent("\(sessionId).jsonl")
        if sessionsListRegularNonEmptyFileExists(atPath: nestedMessagesPath) {
            return nestedMessagesPath
        }
        return nil
    }

    private func sessionsListClaudeSessionIdIsSafeFilename(_ sessionId: String) -> Bool {
        sessionId.range(of: #"[\\/]"#, options: .regularExpression) == nil
            && !sessionId.isEmpty
            && sessionId != "."
            && sessionId != ".."
    }

    private func sessionsListEncodeClaudeProjectDir(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func sessionsListDirectoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func sessionsListForkSupport(
        agent: String,
        record: ClaudeHookSessionRecord,
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
        if record.launchCommand?.launcher == "omo" {
            return (true, "available")
        }
        if sessionsListOpenCodeLooksRemoteLike(record) {
            return (true, "available")
        }
        if let executable = sessionsListOpenCodeProbeExecutable(record),
           executable.hasPrefix("/"),
           !FileManager.default.isExecutableFile(atPath: executable) {
            return (false, "opencode_executable_missing")
        }
        if sessionsListOpenCodeVersionProbeSupportsFork(record) {
            return (true, "available")
        }
        return (false, "opencode_version_unverified")
    }

    private func sessionsListOpenCodeLooksRemoteLike(_ record: ClaudeHookSessionRecord) -> Bool {
        guard let workingDirectory = sessionsListNormalized(
            record.launchCommand?.workingDirectory ?? record.cwd
        ) else {
            return false
        }
        var isDirectory: ObjCBool = false
        return !FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory)
            || !isDirectory.boolValue
    }

    private func sessionsListOpenCodeProbeExecutable(_ record: ClaudeHookSessionRecord) -> String? {
        if let executablePath = sessionsListNormalized(record.launchCommand?.executablePath) {
            return executablePath
        }
        return record.launchCommand?.arguments.first.flatMap(sessionsListNormalized)
    }

    private func sessionsListOpenCodeVersionProbeSupportsFork(_ record: ClaudeHookSessionRecord) -> Bool {
        guard let executable = sessionsListOpenCodeProbeExecutable(record) else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable, "--version"]
        process.environment = sessionsListOpenCodeProbeEnvironment(record)
        if let workingDirectory = sessionsListNormalized(record.launchCommand?.workingDirectory ?? record.cwd),
           sessionsListDirectoryExists(atPath: workingDirectory) {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return false
        }
        guard ((try? waitForProcessExit(process, timeout: 2.0)) ?? false) else {
            process.terminate()
            _ = try? waitForProcessExit(process, timeout: 0.5)
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return false
        }
        return sessionsListOpenCodeVersionSupportsFork(output)
    }

    private func sessionsListOpenCodeProbeEnvironment(_ record: ClaudeHookSessionRecord) -> [String: String] {
        let safeBaseKeys = ["HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "PATH", "TMPDIR", "USER"]
        var environment: [String: String] = [:]
        let baseEnvironment = ProcessInfo.processInfo.environment
        for key in safeBaseKeys {
            if let value = baseEnvironment[key],
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                environment[key] = value
            }
        }
        let selectedEnvironment = AgentLaunchEnvironmentPolicy.selectedEnvironment(
            from: record.launchCommand?.environment ?? [:]
        )
        for (key, value) in selectedEnvironment {
            environment[key] = value
        }
        if let path = record.launchCommand?.environment?["PATH"],
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            environment["PATH"] = path
        } else if environment["PATH"] == nil {
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        return environment
    }

    private func sessionsListOpenCodeVersionSupportsFork(_ output: String) -> Bool {
        guard let version = sessionsListFirstSemanticVersion(in: output) else {
            return false
        }
        return version >= (1, 14, 50)
    }

    private func sessionsListFirstSemanticVersion(in output: String) -> (Int, Int, Int)? {
        let pattern = #"\b(\d+)\.(\d+)\.(\d+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: output,
                  range: NSRange(output.startIndex..<output.endIndex, in: output)
              ),
              match.numberOfRanges == 4,
              let majorRange = Range(match.range(at: 1), in: output),
              let minorRange = Range(match.range(at: 2), in: output),
              let patchRange = Range(match.range(at: 3), in: output),
              let major = Int(output[majorRange]),
              let minor = Int(output[minorRange]),
              let patch = Int(output[patchRange]) else {
            return nil
        }
        return (major, minor, patch)
    }

    private func sessionsListForkArguments(
        agent: String,
        record: ClaudeHookSessionRecord
    ) -> [String]? {
        let normalizedSessionId = record.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionId.isEmpty else { return nil }
        let forkArgv = AgentForkArgv()
        switch forkArgv.launcherResolution(
            launcher: record.launchCommand?.launcher,
            sessionId: normalizedSessionId,
            executablePath: record.launchCommand?.executablePath,
            arguments: record.launchCommand?.arguments ?? []
        ) {
        case .resolved(let argv):
            return argv
        case .passthrough:
            return forkArgv.builtInKind(
                kind: agent,
                sessionId: normalizedSessionId,
                executablePath: record.launchCommand?.executablePath,
                arguments: record.launchCommand?.arguments ?? []
            )
        }
    }

    private func sessionsListForkStartupInputAvailable(
        arguments: [String],
        agent: String,
        record: ClaudeHookSessionRecord
    ) -> Bool {
        let command = sessionsListForkShellCommand(arguments: arguments, agent: agent, record: record)
        return (command + "\n").utf8.count <= 900
    }

    private func sessionsListForkShellCommand(
        arguments: [String],
        agent: String,
        record: ClaudeHookSessionRecord
    ) -> String {
        var commandParts: [String] = []
        let selectedEnvironment = AgentLaunchEnvironmentPolicy.selectedEnvironment(
            from: record.launchCommand?.environment ?? [:],
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

        let workingDirectory = sessionsListNormalized(record.launchCommand?.workingDirectory ?? record.cwd)
        let sanitizedCommandParts = AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
            from: commandParts,
            workingDirectory: workingDirectory
        )
        let shellCommand = agent == "claude"
            ? AgentResumeArgv.renderedPortableClaudeResumeShellCommand(
                parts: sanitizedCommandParts,
                quote: sessionsListShellSingleQuoted
            )
            : sanitizedCommandParts.map(sessionsListShellSingleQuoted).joined(separator: " ")
        return sessionsListWorkingDirectoryPrefixed(shellCommand, workingDirectory: workingDirectory)
    }

    private func sessionsListWorkingDirectoryPrefixed(_ command: String, workingDirectory: String?) -> String {
        guard let workingDirectory else { return command }
        let quoted = sessionsListShellSingleQuoted(workingDirectory)
        return "{ cd -- \(quoted) 2>/dev/null || [ ! -d \(quoted) ]; } && \(command)"
    }

    private func sessionsListShellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
