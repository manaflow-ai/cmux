import Foundation
import CMUXAgentLaunch
import Darwin

extension CMUXCLI {
    private typealias SessionListAgentSpec = (name: String, displayName: String, sessionStoreSuffix: String, configDirEnvOverride: String?)
    private typealias SessionListEntry = (updatedAt: TimeInterval, payload: [String: Any])
    private typealias CodexSessionListIndex = (indexedSessionIds: Set<String>, transcriptPathBySessionId: [String: String])

    func runSessionsCommand(
        commandArgs rawArgs: [String],
        jsonOutput: Bool,
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws {
        var args = rawArgs
        let subcommand = args.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if subcommand == "debug" || subcommand == "list" {
            args.removeFirst()
        } else if subcommand == "help" {
            print(sessionsUsage())
            return
        } else if let subcommand, !subcommand.hasPrefix("-") {
            throw CLIError(message: String(
                format: String(localized: "cli.sessions.error.unknownSubcommand", defaultValue: "Unknown sessions subcommand: %@. Usage: cmux sessions list [options]"),
                subcommand
            ))
        }

        let (agentRaw, rem0) = parseOption(args, name: "--agent")
        let (sessionRaw, rem1) = parseOption(rem0, name: "--session")
        let (workspaceRaw, rem2) = parseOption(rem1, name: "--workspace")
        let (surfaceRaw, rem3) = parseOption(rem2, name: "--surface")
        let (cwdRaw, rem4) = parseOption(rem3, name: "--cwd")
        let (stateDirRaw, rem5) = parseOption(rem4, name: "--state-dir")
        let (codexHomeRaw, rem6) = parseOption(rem5, name: "--codex-home")
        let (limitRaw, rem7) = parseOption(rem6, name: "--limit")

        var includeAll = false
        var localJSONOutput = jsonOutput
        var remaining: [String] = []
        for arg in rem7 {
            switch arg {
            case "--all":
                includeAll = true
            case "--json":
                localJSONOutput = true
            default:
                remaining.append(arg)
            }
        }
        if let unknown = remaining.first(where: { $0.hasPrefix("-") }) {
            throw CLIError(message: String(
                format: String(localized: "cli.sessions.error.unknownFlag", defaultValue: "sessions list: unknown flag '%@'"),
                unknown
            ))
        }
        if let extra = remaining.first {
            throw CLIError(message: String(
                format: String(localized: "cli.sessions.error.unexpectedArgument", defaultValue: "sessions list: unexpected argument '%@'"),
                extra
            ))
        }

        let limit: Int
        if includeAll {
            limit = Int.max
        } else if let limitRaw {
            guard let parsed = Int(limitRaw), parsed > 0 else {
                throw CLIError(message: String(localized: "cli.sessions.error.invalidLimit", defaultValue: "sessions list: --limit must be a positive integer"))
            }
            limit = parsed
        } else {
            limit = 100
        }

        let stateDir = sessionsListExpandedPath(
            stateDirRaw
                ?? processEnv["CMUX_AGENT_HOOK_STATE_DIR"]
                ?? URL(fileURLWithPath: processEnv["HOME"] ?? NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent(".cmuxterm", isDirectory: true)
                    .path
        )
        let defaultCodexHome = sessionsListExpandedPath(
            codexHomeRaw
                ?? processEnv["CODEX_HOME"]
                ?? URL(fileURLWithPath: processEnv["HOME"] ?? NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent(".codex", isDirectory: true)
                    .path
        )
        let homeDirectory = sessionsListExpandedPath(processEnv["HOME"] ?? NSHomeDirectory())

        let agentSpecs = sessionsListAgentSpecs()
        let selectedSpecs: [SessionListAgentSpec]
        if let agentRaw {
            let normalized = agentRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else {
                throw CLIError(message: String(localized: "cli.sessions.error.agentRequiresValue", defaultValue: "sessions list: --agent requires a value"))
            }
            if normalized == "claude" || normalized == "claude-code" || normalized == "claude_code" {
                selectedSpecs = agentSpecs.filter { $0.name == "claude" }
            } else if let def = Self.agentDef(named: normalized) {
                selectedSpecs = agentSpecs.filter { $0.name == def.name }
            } else {
                throw CLIError(message: String(
                    format: String(localized: "cli.sessions.error.unknownAgent", defaultValue: "sessions list: unknown agent '%@'"),
                    agentRaw
                ))
            }
        } else {
            selectedSpecs = agentSpecs
        }

        let sessionFilter = sessionsListNormalized(sessionRaw)?.lowercased()
        let workspaceFilter = sessionsListNormalizedIDRef(workspaceRaw)?.lowercased()
        let surfaceFilter = sessionsListNormalizedIDRef(surfaceRaw)?.lowercased()
        let cwdFilter = sessionsListNormalized(cwdRaw)?.lowercased()
        var codexIndexes: [String: CodexSessionListIndex] = [:]
        var entries: [SessionListEntry] = []
        var stores: [[String: Any]] = []

        let decoder = JSONDecoder()
        for spec in selectedSpecs {
            let storePath = URL(fileURLWithPath: stateDir, isDirectory: true)
                .appendingPathComponent("\(spec.sessionStoreSuffix)-hook-sessions.json", isDirectory: false)
                .path
            var storePayload: [String: Any] = [
                "agent": spec.name,
                "path": storePath,
                "exists": fileManager.fileExists(atPath: storePath)
            ]

            guard fileManager.fileExists(atPath: storePath) else {
                storePayload["session_count"] = 0
                stores.append(storePayload)
                continue
            }

            let storeData = try Data(contentsOf: URL(fileURLWithPath: storePath))
            let store = try decoder.decode(ClaudeHookSessionStoreFile.self, from: storeData)
            storePayload["session_count"] = store.sessions.count
            stores.append(storePayload)

            for record in store.sessions.values {
                guard sessionFilter == nil || record.sessionId.lowercased() == sessionFilter else { continue }
                guard workspaceFilter == nil || record.workspaceId.lowercased() == workspaceFilter else { continue }
                guard surfaceFilter == nil || record.surfaceId.lowercased() == surfaceFilter else { continue }
                if let cwdFilter {
                    let cwd = (record.cwd ?? "").lowercased()
                    let launchCwd = (record.launchCommand?.workingDirectory ?? "").lowercased()
                    guard cwd.contains(cwdFilter) || launchCwd.contains(cwdFilter) else { continue }
                }

                var payload: [String: Any] = [
                    "agent": spec.name,
                    "agent_display_name": spec.displayName,
                    "session_id": record.sessionId,
                    "workspace_id": record.workspaceId,
                    "surface_id": record.surfaceId,
                    "store_path": storePath,
                    "started_at": sessionsListTimestamp(record.startedAt),
                    "updated_at": sessionsListTimestamp(record.updatedAt),
                    "updated_at_unix": record.updatedAt
                ]
                payload["cwd"] = record.cwd ?? NSNull()
                payload["transcript_path"] = record.transcriptPath ?? NSNull()
                payload["pid"] = record.pid ?? NSNull()
                payload["runtime_status"] = record.runtimeStatus?.rawValue ?? NSNull()
                payload["agent_lifecycle"] = record.agentLifecycle?.rawValue ?? NSNull()
                payload["last_prompt_turn_id"] = record.lastPromptTurnId ?? NSNull()
                payload["active_prompt_turn_id"] = record.activePromptTurnId ?? NSNull()
                payload["launch_working_directory"] = record.launchCommand?.workingDirectory ?? NSNull()
                payload["launch_arguments"] = record.launchCommand?.arguments ?? []
                payload.merge(
                    sessionsListForkDiagnostics(
                        agent: spec.name,
                        record: record,
                        homeDirectory: homeDirectory
                    ),
                    uniquingKeysWith: { _, new in new }
                )

                let workspaceActive = store.activeSessionsByWorkspace[record.workspaceId]
                let surfaceActive = store.activeSessionsBySurface[record.surfaceId]
                payload["active_for_workspace"] = workspaceActive?.sessionId == record.sessionId
                payload["active_for_surface"] = surfaceActive?.sessionId == record.sessionId
                payload["active_workspace_session_id"] = workspaceActive?.sessionId ?? NSNull()
                payload["active_surface_session_id"] = surfaceActive?.sessionId ?? NSNull()

                if spec.name == "codex" {
                    let codexHome = sessionsListExpandedPath(
                        sessionsListNormalized(record.launchCommand?.environment?["CODEX_HOME"]) ?? defaultCodexHome
                    )
                    let index = try codexIndexes[codexHome] ?? buildCodexDebugIndex(
                        codexHome: codexHome,
                        fileManager: fileManager
                    )
                    codexIndexes[codexHome] = index
                    let transcriptPath = index.transcriptPathBySessionId[record.sessionId]
                    payload["session_home"] = codexHome
                    payload["session_dir"] = URL(fileURLWithPath: codexHome, isDirectory: true)
                        .appendingPathComponent("sessions", isDirectory: true)
                        .path
                    payload["codex_indexed"] = index.indexedSessionIds.contains(record.sessionId)
                    payload["codex_transcript_found"] = transcriptPath != nil
                    payload["codex_transcript_path"] = transcriptPath ?? NSNull()
                } else if let envKey = spec.configDirEnvOverride,
                          let value = sessionsListNormalized(record.launchCommand?.environment?[envKey]) {
                    payload["session_home"] = sessionsListExpandedPath(value)
                    payload["session_dir"] = sessionsListExpandedPath(value)
                } else {
                    payload["session_home"] = NSNull()
                    payload["session_dir"] = NSNull()
                }

                entries.append((updatedAt: record.updatedAt, payload: payload))
            }
        }

        let sortedEntries = entries.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            let lhs = ($0.payload["session_id"] as? String) ?? ""
            let rhs = ($1.payload["session_id"] as? String) ?? ""
            return lhs < rhs
        }
        let limitedEntries = Array(sortedEntries.prefix(limit))

        if localJSONOutput {
            print(jsonString([
                "state_dir": stateDir,
                "default_codex_home": defaultCodexHome,
                "total_matches": sortedEntries.count,
                "limit": limit == Int.max ? NSNull() : limit,
                "stores": stores,
                "sessions": limitedEntries.map(\.payload)
            ]))
            return
        }

        if limitedEntries.isEmpty {
            print(String(localized: "cli.sessions.output.noMatches", defaultValue: "No saved agent sessions matched."))
            print("state_dir=\(stateDir)")
            return
        }

        for entry in limitedEntries {
            print(renderSessionListLine(entry.payload))
        }
        if sortedEntries.count > limitedEntries.count {
            print(String(
                format: String(localized: "cli.sessions.output.more", defaultValue: "... %lld more. Pass --all or --limit <n>."),
                sortedEntries.count - limitedEntries.count
            ))
        }
    }

    func sessionsUsage() -> String {
        String(localized: "cli.sessions.usage", defaultValue: """
        Usage: cmux sessions list [options]
               cmux sessions [options]

        Print saved agent session records from ~/.cmuxterm/*-hook-sessions.json.
        This command does not require a running cmux socket.

        Options:
          --agent <name>        Filter to one agent, for example codex or claude
          --session <id>        Filter to one agent session id
          --workspace <id>      Filter to one saved workspace id
          --surface <id>        Filter to one saved surface id
          --cwd <text>          Filter by saved cwd or launch working directory
          --state-dir <path>    Override hook state directory
          --codex-home <path>   Override the default Codex home used for transcript checks
          --limit <n>           Limit text output (default: 100)
          --all                 Print all matches
          --json                Print structured JSON

        Codex rows include whether the saved id exists in CODEX_HOME/session_index.jsonl
        and whether a matching transcript file exists under CODEX_HOME/sessions or
        CODEX_HOME/archived_sessions.

        Compatibility aliases:
          cmux sessions debug [options]
          cmux session-debug [options]
        """)
    }

    private func sessionsListAgentSpecs() -> [SessionListAgentSpec] {
        var specs: [SessionListAgentSpec] = [
            (
                name: "claude",
                displayName: "Claude Code",
                sessionStoreSuffix: "claude",
                configDirEnvOverride: "CLAUDE_CONFIG_DIR"
            )
        ]
        specs.append(contentsOf: Self.agentDefs.map {
            (
                name: $0.name,
                displayName: $0.displayName,
                sessionStoreSuffix: $0.sessionStoreSuffix,
                configDirEnvOverride: $0.configDirEnvOverride
            )
        })
        return specs
    }

    private func buildCodexDebugIndex(
        codexHome: String,
        fileManager: FileManager
    ) throws -> CodexSessionListIndex {
        let homeURL = URL(fileURLWithPath: codexHome, isDirectory: true)
        var indexedSessionIds = Set<String>()
        let sessionIndexURL = homeURL.appendingPathComponent("session_index.jsonl", isDirectory: false)
        if let contents = try? String(contentsOf: sessionIndexURL, encoding: .utf8) {
            for line in contents.split(separator: "\n") {
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = sessionsListNormalized(object["id"] as? String) else {
                    continue
                }
                indexedSessionIds.insert(id)
            }
        }

        var transcriptPathBySessionId: [String: String] = [:]
        let transcriptRoots = [
            homeURL.appendingPathComponent("sessions", isDirectory: true),
            homeURL.appendingPathComponent("archived_sessions", isDirectory: true)
        ]
        for root in transcriptRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl" else { continue }
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile != false else { continue }
                for id in sessionsListUUIDs(in: fileURL.lastPathComponent) where transcriptPathBySessionId[id] == nil {
                    transcriptPathBySessionId[id] = fileURL.path
                }
            }
        }

        return (
            indexedSessionIds: indexedSessionIds,
            transcriptPathBySessionId: transcriptPathBySessionId
        )
    }

    private func sessionsListUUIDs(in value: String) -> [String] {
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: value) else { return nil }
            return String(value[matchRange]).lowercased()
        }
    }

    private func renderSessionListLine(_ payload: [String: Any]) -> String {
        let agent = (payload["agent"] as? String) ?? "unknown"
        let sessionId = (payload["session_id"] as? String) ?? "unknown"
        let workspaceId = (payload["workspace_id"] as? String) ?? "-"
        let surfaceId = (payload["surface_id"] as? String) ?? "-"
        let cwd = (payload["cwd"] as? String) ?? "-"
        let updatedAt = (payload["updated_at"] as? String) ?? "-"
        let sessionDir = (payload["session_dir"] as? String) ?? "-"
        let activeWorkspace = ((payload["active_for_workspace"] as? Bool) == true) ? "yes" : "no"
        let activeSurface = ((payload["active_for_surface"] as? Bool) == true) ? "yes" : "no"
        var parts = [
            "\(agent) \(sessionId)",
            "workspace=\(workspaceId)",
            "surface=\(surfaceId)",
            "cwd=\(cwd)",
            "session_dir=\(sessionDir)",
            "active_ws=\(activeWorkspace)",
            "active_surface=\(activeSurface)",
            "updated=\(updatedAt)"
        ]
        if agent == "codex" {
            let indexed = ((payload["codex_indexed"] as? Bool) == true) ? "yes" : "no"
            let transcript = ((payload["codex_transcript_found"] as? Bool) == true) ? "yes" : "no"
            parts.append("codex_indexed=\(indexed)")
            parts.append("codex_transcript=\(transcript)")
        }
        let forkCommandAvailable = ((payload["fork_command_available"] as? Bool) == true) ? "yes" : "no"
        parts.append("fork_command=\(forkCommandAvailable)")
        let forkSupported = ((payload["fork_supported"] as? Bool) == true) ? "yes" : "no"
        parts.append("fork=\(forkSupported)")
        if let pidExists = payload["stored_pid_exists"] as? Bool {
            parts.append("pid_exists=\(pidExists ? "yes" : "no")")
        }
        return parts.joined(separator: "  ")
    }

    private func sessionsListTimestamp(_ value: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: value))
    }

    private func sessionsListExpandedPath(_ value: String) -> String {
        NSString(string: value).expandingTildeInPath
    }

    private func sessionsListNormalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func sessionsListNormalizedIDRef(_ value: String?) -> String? {
        guard let normalized = sessionsListNormalized(value) else { return nil }
        if UUID(uuidString: normalized) != nil {
            return normalized
        }
        if let uuid = sessionsListUUIDs(in: normalized).last {
            return uuid
        }
        return normalized
    }

    private func sessionsListForkDiagnostics(
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
            "stale_pid_blocks_restore_in_0_64_17": hookRecordRestorable && record.pid != nil && storedPIDExists == false,
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
