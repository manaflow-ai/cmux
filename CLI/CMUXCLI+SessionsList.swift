import Foundation

extension CMUXCLI {
    private typealias SessionListAgentSpec = (name: String, displayName: String, sessionStoreSuffix: String, configDirEnvOverride: String?)
    private typealias SessionListEntry = (updatedAt: TimeInterval, payload: [String: Any])
    private typealias CodexSessionListIndex = (indexedSessionIds: Set<String>, transcriptPathBySessionId: [String: String])

    func runSessionsCommand(
        commandArgs rawArgs: [String],
        jsonOutput: Bool,
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        outputSchemaVersion: Int? = nil
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
        let hasRecordFilter = sessionFilter != nil || workspaceFilter != nil || surfaceFilter != nil || cwdFilter != nil
        var codexIndexes: [String: CodexSessionListIndex] = [:]
        let claudeTranscriptLookup = SessionsListClaudeTranscriptLookupCache(homeDirectory: homeDirectory)
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

            for rawRecord in store.sessions.values {
                let record = spec.name == "claude"
                    ? sessionsListResolvedClaudeWorkflowRecord(rawRecord, lookup: claudeTranscriptLookup)
                    : rawRecord
                let rawSessionId = rawRecord.sessionId.lowercased()
                let resolvedSessionId = record.sessionId.lowercased()
                guard sessionFilter == nil || rawSessionId == sessionFilter || resolvedSessionId == sessionFilter else {
                    continue
                }
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
                if rawRecord.sessionId != record.sessionId {
                    payload["hook_session_id"] = rawRecord.sessionId
                }
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
                        claudeTranscriptLookup: claudeTranscriptLookup
                    ),
                    uniquingKeysWith: { _, new in new }
                )

                let workspaceActive = store.activeSessionsByWorkspace[record.workspaceId]
                let surfaceActive = store.activeSessionsBySurface[record.surfaceId]
                let activeForWorkspace = workspaceActive?.sessionId == record.sessionId
                    || workspaceActive?.sessionId == rawRecord.sessionId
                let activeForSurface = surfaceActive?.sessionId == record.sessionId
                    || surfaceActive?.sessionId == rawRecord.sessionId
                payload["active_for_workspace"] = activeForWorkspace
                payload["active_for_surface"] = activeForSurface
                payload["active_workspace_session_id"] = workspaceActive?.sessionId ?? NSNull()
                payload["active_surface_session_id"] = surfaceActive?.sessionId ?? NSNull()
                payload["is_restorable"] = record.isRestorable ?? NSNull()
                payload["run_id"] = record.runId ?? record.sessionId
                payload["parent_run_id"] = record.parentRunId ?? NSNull()
                payload["parent_session_id"] = record.parentSessionId ?? NSNull()
                payload["relationship"] = record.relationship ?? NSNull()
                payload["restore_authority"] = record.restoreAuthority ?? record.isRestorable ?? false

                var transcriptBacked = false

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
                    let savedTranscriptPath = sessionsListNormalized(record.transcriptPath)
                    let expandedSavedTranscriptPath = savedTranscriptPath.map { sessionsListExpandedPath($0) }
                    payload["session_home"] = codexHome
                    payload["session_dir"] = URL(fileURLWithPath: codexHome, isDirectory: true)
                        .appendingPathComponent("sessions", isDirectory: true)
                        .path
                    payload["codex_indexed"] = index.indexedSessionIds.contains(record.sessionId)
                    payload["codex_transcript_found"] = transcriptPath != nil || expandedSavedTranscriptPath.map { fileManager.fileExists(atPath: $0) } == true
                    payload["codex_transcript_path"] = transcriptPath ?? expandedSavedTranscriptPath ?? NSNull()
                    transcriptBacked = payload["codex_transcript_found"] as? Bool == true
                } else if let envKey = spec.configDirEnvOverride,
                          let value = sessionsListNormalized(record.launchCommand?.environment?[envKey]) {
                    payload["session_home"] = sessionsListExpandedPath(value)
                    payload["session_dir"] = sessionsListExpandedPath(value)
                    if let transcriptPath = sessionsListNormalized(record.transcriptPath) {
                        transcriptBacked = fileManager.fileExists(atPath: sessionsListExpandedPath(transcriptPath))
                    }
                } else {
                    payload["session_home"] = NSNull()
                    payload["session_dir"] = NSNull()
                    if let transcriptPath = sessionsListNormalized(record.transcriptPath) {
                        transcriptBacked = fileManager.fileExists(atPath: sessionsListExpandedPath(transcriptPath))
                    }
                }
                payload["transcript_backed"] = transcriptBacked
                let launchBacked = record.launchCommand != nil && agentHookSessionHasDurableResumeEvidence(
                    kind: spec.name,
                    launchCommand: record.launchCommand
                )
                payload["launch_backed"] = launchBacked

                let defaultVisible = activeForWorkspace
                    || activeForSurface
                    || record.isRestorable == true
                    || launchBacked
                    || transcriptBacked
                payload["default_visible"] = defaultVisible
                guard includeAll || hasRecordFilter || defaultVisible else {
                    continue
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
            var output: [String: Any] = [
                "state_dir": stateDir,
                "default_codex_home": defaultCodexHome,
                "total_matches": sortedEntries.count,
                "limit": limit == Int.max ? NSNull() : limit,
                "stores": stores,
                "sessions": limitedEntries.map(\.payload)
            ]
            if let outputSchemaVersion {
                output["schema_version"] = outputSchemaVersion
            }
            print(jsonString(output))
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

    func runAgentsCommand(
        commandArgs: [String],
        jsonOutput: Bool,
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws {
        let subcommand = commandArgs.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch subcommand {
        case nil, "", "list", "debug":
            try runSessionsCommand(
                commandArgs: commandArgs,
                jsonOutput: jsonOutput,
                processEnv: processEnv,
                fileManager: fileManager,
                outputSchemaVersion: 2
            )
        case "tree":
            try runAgentsTreeCommand(
                commandArgs: Array(commandArgs.dropFirst()),
                jsonOutput: jsonOutput,
                processEnv: processEnv,
                fileManager: fileManager
            )
        case "help":
            print(agentsUsage())
        case let subcommand?:
            throw CLIError(message: String(
                format: String(
                    localized: "cli.agents.error.unknownSubcommand",
                    defaultValue: "Unknown agents subcommand: %@. Usage: cmux agents <list|tree> [options]"
                ),
                subcommand
            ))
        }
    }

    private func runAgentsTreeCommand(
        commandArgs: [String],
        jsonOutput: Bool,
        processEnv: [String: String],
        fileManager: FileManager
    ) throws {
        let (agentRaw, remainder0) = parseOption(commandArgs, name: "--agent")
        let (sessionRaw, remainder1) = parseOption(remainder0, name: "--session")
        let (workspaceRaw, remainder2) = parseOption(remainder1, name: "--workspace")
        let (surfaceRaw, remainder3) = parseOption(remainder2, name: "--surface")
        let (stateDirRaw, remainder4) = parseOption(remainder3, name: "--state-dir")
        let (depthRaw, remainder5) = parseOption(remainder4, name: "--depth")
        let (maximumNodesRaw, remainder6) = parseOption(remainder5, name: "--max-nodes")

        var includeAll = false
        var localJSONOutput = jsonOutput
        var remaining: [String] = []
        for argument in remainder6 {
            switch argument {
            case "--all", "--history": includeAll = true
            case "--json": localJSONOutput = true
            default: remaining.append(argument)
            }
        }
        if let unknown = remaining.first(where: { $0.hasPrefix("-") }) {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.agents.tree.error.unknownFlag",
                    defaultValue: "agents tree: unknown flag '%@'"
                ),
                unknown
            ))
        }
        if let extra = remaining.first {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.agents.tree.error.unexpectedArgument",
                    defaultValue: "agents tree: unexpected argument '%@'"
                ),
                extra
            ))
        }

        let maximumDepth: Int
        if let depthRaw {
            guard let parsed = Int(depthRaw), parsed > 0, parsed <= 4_096 else {
                throw CLIError(message: String(
                    localized: "cli.agents.tree.error.invalidDepth",
                    defaultValue: "agents tree: --depth must be an integer from 1 through 4096"
                ))
            }
            maximumDepth = parsed
        } else {
            maximumDepth = 64
        }
        let maximumNodes: Int
        if let maximumNodesRaw {
            guard let parsed = Int(maximumNodesRaw), parsed > 0, parsed <= 20_000 else {
                throw CLIError(message: String(
                    localized: "cli.agents.tree.error.invalidMaximumNodes",
                    defaultValue: "agents tree: --max-nodes must be an integer from 1 through 20000"
                ))
            }
            maximumNodes = parsed
        } else {
            maximumNodes = 10_000
        }

        let stateDirectory = sessionsListExpandedPath(
            stateDirRaw
                ?? processEnv["CMUX_AGENT_HOOK_STATE_DIR"]
                ?? URL(fileURLWithPath: processEnv["HOME"] ?? NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent(".cmuxterm", isDirectory: true)
                    .path
        )
        let selectedSpecs: [SessionListAgentSpec]
        if let agentRaw {
            let normalized = agentRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["claude", "claude-code", "claude_code"].contains(normalized) {
                selectedSpecs = sessionsListAgentSpecs().filter { $0.name == "claude" }
            } else if let definition = Self.agentDef(named: normalized) {
                selectedSpecs = sessionsListAgentSpecs().filter { $0.name == definition.name }
            } else {
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.agents.tree.error.unknownAgent",
                        defaultValue: "agents tree: unknown agent '%@'"
                    ),
                    agentRaw
                ))
            }
        } else {
            selectedSpecs = sessionsListAgentSpecs()
        }

        let sessionFilter = sessionsListNormalized(sessionRaw)?.lowercased()
        let workspaceFilter = sessionsListNormalizedIDRef(workspaceRaw)?.lowercased()
        let surfaceFilter = sessionsListNormalizedIDRef(surfaceRaw)?.lowercased()
        let decoder = JSONDecoder()
        var nodes: [[String: Any]] = []
        var nodeByRunKey: [String: [String: Any]] = [:]
        var nodeBySessionKey: [String: [String: Any]] = [:]

        for spec in selectedSpecs {
            let storeURL = URL(fileURLWithPath: stateDirectory, isDirectory: true)
                .appendingPathComponent("\(spec.sessionStoreSuffix)-hook-sessions.json", isDirectory: false)
            guard fileManager.fileExists(atPath: storeURL.path) else { continue }
            let store = try decoder.decode(
                ClaudeHookSessionStoreFile.self,
                from: Data(contentsOf: storeURL)
            )
            for record in store.sessions.values {
                guard sessionFilter == nil || record.sessionId.lowercased() == sessionFilter else { continue }
                guard workspaceFilter == nil || record.workspaceId.lowercased() == workspaceFilter else { continue }
                guard surfaceFilter == nil || record.surfaceId.lowercased() == surfaceFilter else { continue }
                let activeForWorkspace = store.activeSessionsByWorkspace[record.workspaceId]?.sessionId == record.sessionId
                let activeForSurface = store.activeSessionsBySurface[record.surfaceId]?.sessionId == record.sessionId
                let restoreAuthority = record.restoreAuthority ?? record.isRestorable ?? false
                guard includeAll || sessionFilter != nil || workspaceFilter != nil || surfaceFilter != nil
                        || activeForWorkspace || activeForSurface || restoreAuthority else {
                    continue
                }
                guard nodes.count < maximumNodes else {
                    throw CLIError(message: String(
                        format: String(
                            localized: "cli.agents.tree.error.nodeLimit",
                            defaultValue: "agents tree: more than %lld nodes matched; narrow the filters or raise --max-nodes"
                        ),
                        maximumNodes
                    ))
                }
                let runID = sessionsListNormalized(record.runId) ?? record.sessionId
                let nodeID = agentSessionNodeID(
                    agent: spec.name,
                    sessionID: record.sessionId,
                    runID: runID
                )
                let node: [String: Any] = [
                    "node_id": nodeID,
                    "agent": spec.name,
                    "agent_display_name": spec.displayName,
                    "session_id": record.sessionId,
                    "run_id": runID,
                    "parent_run_id": record.parentRunId ?? NSNull(),
                    "parent_session_id": record.parentSessionId ?? NSNull(),
                    "relationship": record.relationship ?? NSNull(),
                    "workspace_id": record.workspaceId,
                    "surface_id": record.surfaceId,
                    "restore_authority": restoreAuthority,
                    "runtime_status": record.runtimeStatus?.rawValue ?? NSNull(),
                    "agent_lifecycle": record.agentLifecycle?.rawValue ?? NSNull(),
                    "started_at_unix": record.startedAt,
                    "updated_at_unix": record.updatedAt,
                ]
                nodes.append(node)
                nodeByRunKey[agentSessionGraphKey(agent: spec.name, identifier: runID)] = node
                nodeBySessionKey[agentSessionGraphKey(agent: spec.name, identifier: record.sessionId)] = node
            }
        }

        nodes.sort {
            let lhs = ($0["started_at_unix"] as? TimeInterval) ?? 0
            let rhs = ($1["started_at_unix"] as? TimeInterval) ?? 0
            if lhs != rhs { return lhs < rhs }
            return (($0["node_id"] as? String) ?? "") < (($1["node_id"] as? String) ?? "")
        }
        let edges = nodes.compactMap { node -> [String: Any]? in
            guard let agent = node["agent"] as? String,
                  let childNodeID = node["node_id"] as? String,
                  let childRunID = node["run_id"] as? String,
                  let childSessionID = node["session_id"] as? String else { return nil }
            let parent = (node["parent_run_id"] as? String).flatMap {
                nodeByRunKey[agentSessionGraphKey(agent: agent, identifier: $0)]
            } ?? (node["parent_session_id"] as? String).flatMap {
                nodeBySessionKey[agentSessionGraphKey(agent: agent, identifier: $0)]
            }
            guard let parent,
                  let parentNodeID = parent["node_id"] as? String,
                  let parentRunID = parent["run_id"] as? String,
                  let parentSessionID = parent["session_id"] as? String,
                  parentNodeID != childNodeID else { return nil }
            return [
                "from_node_id": parentNodeID,
                "to_node_id": childNodeID,
                "from_run_id": parentRunID,
                "to_run_id": childRunID,
                "from_session_id": parentSessionID,
                "to_session_id": childSessionID,
                "relationship": (node["relationship"] as? String) ?? "spawned",
            ]
        }.sorted {
            (($0["to_node_id"] as? String) ?? "") < (($1["to_node_id"] as? String) ?? "")
        }

        if localJSONOutput {
            print(jsonString([
                "schema_version": 2,
                "state_dir": stateDirectory,
                "nodes": nodes,
                "edges": edges,
            ]))
            return
        }
        guard !nodes.isEmpty else {
            print(String(
                localized: "cli.agents.tree.output.noMatches",
                defaultValue: "No saved agent sessions matched."
            ))
            print("state_dir=\(stateDirectory)")
            return
        }
        for line in agentSessionTreeLines(nodes: nodes, edges: edges, maximumDepth: maximumDepth) {
            print(line)
        }
    }

    func agentsUsage() -> String {
        String(localized: "cli.agents.usage", defaultValue: """
        Usage: cmux agents list [options]
               cmux agents tree [options]
               cmux agents [options]

        Inspect saved coding-agent sessions without requiring a running cmux socket.
        `agents list` prints the existing session diagnostics as schema version 2 JSON.
        `agents tree` projects saved run and parent metadata into nodes and edges.

        Shared options:
          --agent <name>        Filter to one agent, for example codex or claude
          --session <id>        Filter to one agent session id
          --workspace <id>      Filter to one saved workspace id
          --surface <id>        Filter to one saved surface id
          --state-dir <path>    Override hook state directory
          --all                 Include inactive saved records
          --json                Print structured JSON

        List options:
          --cwd <text>          Filter by saved cwd or launch working directory
          --codex-home <path>   Override the Codex home used for transcript checks
          --limit <n>           Limit rows (default: 100)

        Tree options:
          --depth <n>           Limit text rendering depth (default: 64)
          --max-nodes <n>       Bound graph materialization (default: 10000)

        Compatibility aliases:
          cmux sessions [list] [options]
          cmux session-debug [options]
        """)
    }

    private func agentSessionNodeID(agent: String, sessionID: String, runID: String) -> String {
        "session:\(agent.utf8.count):\(agent)\(sessionID.utf8.count):\(sessionID)\(runID.utf8.count):\(runID)"
    }

    private func agentSessionGraphKey(agent: String, identifier: String) -> String {
        agent + "\u{1F}" + identifier
    }

    private func agentSessionTreeLines(
        nodes: [[String: Any]],
        edges: [[String: Any]],
        maximumDepth: Int
    ) -> [String] {
        let nodesByID = Dictionary(uniqueKeysWithValues: nodes.compactMap { node -> (String, [String: Any])? in
            guard let nodeID = node["node_id"] as? String else { return nil }
            return (nodeID, node)
        })
        let childIDs = Set(edges.compactMap { $0["to_node_id"] as? String })
        let childrenByParent = Dictionary(grouping: edges) { ($0["from_node_id"] as? String) ?? "" }
        var lines: [String] = []
        var visited = Set<String>()

        func appendNode(_ nodeID: String, prefix: String, connector: String, depth: Int) {
            guard let node = nodesByID[nodeID], visited.insert(nodeID).inserted else { return }
            let agent = (node["agent"] as? String) ?? "unknown"
            let sessionID = (node["session_id"] as? String) ?? "unknown"
            let relationship = (node["relationship"] as? String) ?? "root"
            lines.append("\(prefix)\(connector)\(relationship) \(agent) \(sessionID)")
            guard depth < maximumDepth else { return }
            let children = (childrenByParent[nodeID] ?? []).compactMap { edge -> (String, String)? in
                guard let childID = edge["to_node_id"] as? String else { return nil }
                return (childID, (edge["relationship"] as? String) ?? "spawned")
            }.sorted { $0.0 < $1.0 }
            for (index, child) in children.enumerated() {
                let isLast = index == children.count - 1
                appendNode(
                    child.0,
                    prefix: prefix + (connector.isEmpty ? "" : (connector == "└── " ? "    " : "│   ")),
                    connector: isLast ? "└── " : "├── ",
                    depth: depth + 1
                )
            }
        }

        let roots = nodes.compactMap { $0["node_id"] as? String }
            .filter { !childIDs.contains($0) }
            .sorted()
        for root in roots {
            appendNode(root, prefix: "", connector: "", depth: 0)
        }
        for nodeID in nodesByID.keys.sorted() where !visited.contains(nodeID) {
            appendNode(nodeID, prefix: "", connector: "", depth: 0)
        }
        return lines
    }

    func sessionsUsage() -> String {
        String(localized: "cli.sessions.usage", defaultValue: """
        Usage: cmux sessions list [options]
               cmux sessions [options]

        Print saved agent session records from ~/.cmuxterm/*-hook-sessions.json.
        This command does not require a running cmux socket.
        By default, broad output shows active, restorable, or transcript-backed records.
        Pass --all to inspect every saved hook record.

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
        let sessionHome = (payload["session_home"] as? String) ?? "-"
        let sessionDir = (payload["session_dir"] as? String) ?? "-"
        let activeWorkspace = ((payload["active_for_workspace"] as? Bool) == true) ? "yes" : "no"
        let activeSurface = ((payload["active_for_surface"] as? Bool) == true) ? "yes" : "no"
        var parts = [
            "\(agent) \(sessionId)",
            "workspace=\(workspaceId)",
            "surface=\(surfaceId)",
            "cwd=\(cwd)",
            "active_ws=\(activeWorkspace)",
            "active_surface=\(activeSurface)",
            "updated=\(updatedAt)"
        ]
        if agent == "codex" {
            parts.append("session_home=\(sessionHome)")
            let indexed = ((payload["codex_indexed"] as? Bool) == true) ? "yes" : "no"
            let transcript = ((payload["codex_transcript_found"] as? Bool) == true) ? "yes" : "no"
            parts.append("codex_indexed=\(indexed)")
            parts.append("codex_transcript=\(transcript)")
        } else {
            parts.append("session_dir=\(sessionDir)")
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

    func sessionsListExpandedPath(_ value: String) -> String {
        NSString(string: value).expandingTildeInPath
    }

    func sessionsListNormalized(_ value: String?) -> String? {
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

}
