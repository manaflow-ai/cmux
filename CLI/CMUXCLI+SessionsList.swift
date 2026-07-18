import CmuxFoundation
import Foundation
extension CMUXCLI {
    private typealias SessionListAgentSpec = (name: String, displayName: String, sessionStoreSuffix: String, configDirEnvOverride: String?)
    private typealias SessionListEntry = (updatedAt: TimeInterval, payload: [String: Any])
    private typealias CodexSessionListIndex = (indexedSessionIds: Set<String>, transcriptPathBySessionId: [String: String])

    private struct SessionListCandidate {
        var node: AgentSessionGraphNode
        var payload: [String: Any]
    }

    func runSessionsCommand(
        commandArgs rawArgs: [String],
        jsonOutput: Bool,
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        terminalObservations: [CmuxAgentTerminalObservation] = []
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
        let (stateRaw, rem8) = parseOption(rem7, name: "--state")
        let (activityRaw, rem9) = parseOption(rem8, name: "--activity")
        let (workKindRaw, rem10) = parseOption(rem9, name: "--work-kind")

        var includeAll = false
        var localJSONOutput = jsonOutput
        var remaining: [String] = []
        for arg in rem10 {
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
        let requestedAgent = agentRaw.map(agentsNormalizedAgentID)
        var observationAgentIDs: Set<String> = []
        let selectedSpecs: [SessionListAgentSpec]
        if let agentRaw, let normalized = requestedAgent {
            guard !normalized.isEmpty else {
                throw CLIError(message: String(localized: "cli.sessions.error.agentRequiresValue", defaultValue: "sessions list: --agent requires a value"))
            }
            let providerID = agentSessionProviderID(
                for: normalized,
                terminalObservations: terminalObservations
            )
            let hasMatchingObservation = terminalObservations.contains {
                agentTerminalObservation($0, matchesAnyAgentID: [normalized])
            }
            guard providerID != nil || hasMatchingObservation else {
                throw CLIError(message: String(
                    format: String(localized: "cli.sessions.error.unknownAgent", defaultValue: "sessions list: unknown agent '%@'"),
                    agentRaw
                ))
            }
            selectedSpecs = providerID.map { providerID in
                agentSpecs.filter { $0.name == providerID }
            } ?? []
            observationAgentIDs = Set([normalized] + [providerID].compactMap { $0 })
        } else {
            selectedSpecs = agentSpecs
        }

        let sessionFilter = sessionsListNormalized(sessionRaw)?.lowercased()
        let workspaceFilter = sessionsListNormalizedIDRef(workspaceRaw)?.lowercased()
        let surfaceFilter = sessionsListNormalizedIDRef(surfaceRaw)?.lowercased()
        let cwdFilter = sessionsListNormalized(cwdRaw)?.lowercased()
        let stateFilter = sessionsListNormalized(stateRaw)?.lowercased()
        let activityFilter = sessionsListNormalized(activityRaw)?.lowercased()
        let workKindFilter = sessionsListNormalized(workKindRaw)?.lowercased()
        if let stateFilter, AgentEffectiveState(rawValue: stateFilter) == nil {
            throw CLIError(message: String(
                format: String(localized: "cli.agents.list.error.unknownState", defaultValue: "agents list: unknown state '%@'"),
                stateFilter
            ))
        }
        if let activityFilter, AgentActivityState(rawValue: activityFilter) == nil {
            throw CLIError(message: String(
                format: String(localized: "cli.agents.list.error.unknownActivity", defaultValue: "agents list: unknown activity '%@'"),
                activityFilter
            ))
        }
        if let workKindFilter, AgentWorkloadKind(rawValue: workKindFilter) == nil {
            throw CLIError(message: String(
                format: String(localized: "cli.agents.list.error.unknownWorkKind", defaultValue: "agents list: unknown workload kind '%@'"),
                workKindFilter
            ))
        }
        let hasIdentityFilter = sessionFilter != nil || workspaceFilter != nil
            || surfaceFilter != nil || cwdFilter != nil
        let includesEndedRecords = includeAll || hasIdentityFilter || stateFilter == AgentEffectiveState.ended.rawValue
        let queryScope = AgentSessionQueryScope(includeHistory: includeAll, environment: processEnv)
        var codexIndexes: [String: CodexSessionListIndex] = [:]
        let claudeTranscriptLookup = SessionsListClaudeTranscriptLookupCache(homeDirectory: homeDirectory)
        var candidates: [SessionListCandidate] = []
        var activeSessionBySurface: [String: String] = [:]
        var stores: [[String: Any]] = []

        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let snapshots = AgentHookSessionRegistryBridge.snapshots(
            specifications: selectedSpecs.map { (provider: $0.name, suffix: $0.sessionStoreSuffix) },
            stateDirectory: stateDir,
            environment: processEnv,
            fileManager: fileManager
        )
        for spec in selectedSpecs {
            let storePath = URL(fileURLWithPath: stateDir, isDirectory: true)
                .appendingPathComponent("\(spec.sessionStoreSuffix)-hook-sessions.json", isDirectory: false)
                .path
            var storeEnvironment = processEnv
            storeEnvironment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir
            storeEnvironment["CMUX_CLAUDE_HOOK_STATE_PATH"] = storePath
            let bridge = AgentHookSessionRegistryBridge(
                provider: spec.name,
                statePath: storePath,
                environment: storeEnvironment,
                fileManager: fileManager
            )
            let store = snapshots?[spec.name].map { bridge.load(snapshot: $0) }
                ?? ClaudeHookSessionStore(
                    processEnv: storeEnvironment,
                    fileManager: fileManager,
                    agentName: spec.name
                ).snapshot()
            var storePayload: [String: Any] = [
                "agent": spec.name,
                "path": storePath,
                "exists": fileManager.fileExists(atPath: storePath) || !store.sessions.isEmpty
            ]

            guard !store.sessions.isEmpty else {
                storePayload["session_count"] = 0
                stores.append(storePayload)
                continue
            }
            storePayload["session_count"] = store.sessions.count
            stores.append(storePayload)

            for rawRecord in store.sessions.values {
                let rawRunRuntime = rawRecord.runs?
                    .first(where: { $0.runId == rawRecord.activeRunId })?
                    .cmuxRuntime
                    ?? rawRecord.runs?.max(by: { $0.updatedAt < $1.updatedAt })?.cmuxRuntime
                guard queryScope.includes(
                    recordRuntime: rawRecord.cmuxRuntime,
                    runRuntime: rawRunRuntime,
                    legacyVisible: true
                ) else { continue }
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
                    "started_at": sessionsListTimestamp(record.startedAt, formatter: timestampFormatter),
                    "updated_at": sessionsListTimestamp(record.updatedAt, formatter: timestampFormatter),
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
                let projectedRun = record.runs?.first(where: { $0.runId == record.activeRunId })
                    ?? record.runs?.max(by: { $0.updatedAt < $1.updatedAt })
                    ?? AgentSessionRunRecord(
                        runId: record.runId ?? "session:\(spec.name):\(record.sessionId)",
                        pid: record.pid,
                        processStartedAt: nil,
                        cmuxRuntime: record.cmuxRuntime,
                        parentRunId: record.parentRunId,
                        parentSessionId: record.parentSessionId,
                        relationship: record.relationship,
                        restoreAuthority: record.restoreAuthority ?? (record.relationship != .spawned),
                        startedAt: record.startedAt,
                        updatedAt: record.updatedAt,
                        endedAt: record.completedAt
                    )
                guard queryScope.includes(
                    recordRuntime: record.cmuxRuntime,
                    runRuntime: projectedRun.cmuxRuntime,
                    legacyVisible: true
                ) else { continue }
                let projection = AgentSessionStateProjection(record: record, run: projectedRun)
                guard includesEndedRecords || queryScope.includes(projection: projection) else { continue }
                payload["process_state"] = projection.process.rawValue
                payload["session_state"] = projection.session.rawValue
                payload["foreground_state"] = projection.foreground.rawValue
                payload["attention_state"] = projection.attention.rawValue
                payload["effective_state"] = projection.effective.rawValue
                payload["activity"] = sessionsListEncodableJSONObject(projection.activity)
                payload["workloads"] = sessionsListEncodableJSONObject(
                    projection.workloads.map(AgentWorkloadSnapshot.init)
                )
                payload["restore_authority"] = projectedRun.restoreAuthority
                payload["cmux_runtime"] = (projectedRun.cmuxRuntime ?? record.cmuxRuntime)
                    .map { sessionsListEncodableJSONObject($0) } ?? NSNull()
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

                let runtime = projectedRun.cmuxRuntime ?? record.cmuxRuntime
                if activeForSurface, let runtimeID = runtime?.id {
                    activeSessionBySurface[AgentTerminalObservationJoiner.surfaceKey(
                        provider: spec.name,
                        runtimeID: runtimeID,
                        surfaceID: record.surfaceId
                    )] = record.sessionId
                }

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
                    launchCommand: record.launchCommand,
                    transcriptPath: record.transcriptPath
                )
                payload["launch_backed"] = launchBacked

                let legacyDefaultVisible = activeForWorkspace
                    || activeForSurface
                    || (payload["hook_record_restorable"] as? Bool == true)
                let defaultVisible = queryScope.includes(
                    recordRuntime: record.cmuxRuntime,
                    runRuntime: projectedRun.cmuxRuntime,
                    legacyVisible: legacyDefaultVisible
                )
                payload["default_visible"] = defaultVisible
                guard includeAll || hasIdentityFilter
                        || stateFilter == AgentEffectiveState.ended.rawValue
                        || defaultVisible else {
                    continue
                }

                candidates.append(SessionListCandidate(
                    node: AgentSessionGraphNode(
                        provider: spec.name,
                        sessionId: record.sessionId,
                        runId: projectedRun.runId,
                        pid: projectedRun.pid,
                        processStartedAt: projectedRun.processStartedAt,
                        cmuxRuntime: runtime,
                        workspaceId: record.workspaceId,
                        surfaceId: record.surfaceId,
                        cwd: record.cwd,
                        processState: projection.process,
                        sessionState: projection.session,
                        foregroundState: projection.foreground,
                        attentionState: projection.attention,
                        activity: projection.activity,
                        effectiveState: projection.effective,
                        workloads: projection.workloads.map(AgentWorkloadSnapshot.init),
                        restoreAuthority: projectedRun.restoreAuthority,
                        startedAt: projectedRun.startedAt,
                        updatedAt: projectedRun.updatedAt,
                        endedAt: projectedRun.endedAt
                    ),
                    payload: payload
                ))
            }
        }

        let matchingObservations = terminalObservations.filter { observation in
            if !observationAgentIDs.isEmpty,
               !agentTerminalObservation(observation, matchesAnyAgentID: observationAgentIDs) {
                return false
            }
            if let workspaceFilter,
               observation.workspaceID.uuidString.lowercased() != workspaceFilter { return false }
            if let surfaceFilter,
               observation.surfaceID.uuidString.lowercased() != surfaceFilter { return false }
            if let cwdFilter,
               observation.cwd?.lowercased().contains(cwdFilter) != true { return false }
            switch queryScope {
            case .history, .legacyUnscoped:
                return true
            case let .currentRuntime(runtimeID):
                return observation.runtimeID == runtimeID
            }
        }
        let mergedNodes = AgentTerminalObservationJoiner().merge(
            nodes: candidates.map(\.node),
            observations: matchingObservations,
            activeSessionBySurface: activeSessionBySurface
        )
        let candidateByNodeID = candidates.reduce(into: [String: SessionListCandidate]()) { result, candidate in
            result[candidate.node.nodeId] = candidate
        }
        let displayNameByProvider = Dictionary(
            selectedSpecs.map { ($0.name, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        var entries: [SessionListEntry] = []
        for node in mergedNodes {
            if sessionFilter != nil, node.sessionId == nil { continue }
            if let stateFilter, node.effectiveState.rawValue != stateFilter { continue }
            if let activityFilter, node.activity.state.rawValue != activityFilter { continue }
            if let workKindFilter,
               !node.workloads.contains(where: {
                   $0.kind.rawValue == workKindFilter && $0.phase.isActive
               }) { continue }

            if var candidate = candidateByNodeID[node.nodeId] {
                sessionsListApply(node: node, to: &candidate.payload)
                entries.append((updatedAt: node.updatedAt, payload: candidate.payload))
            } else if node.identitySource == "terminal_process" {
                entries.append((
                    updatedAt: node.updatedAt,
                    payload: sessionsListProcessPayload(
                        node: node,
                        displayName: displayNameByProvider[node.provider] ?? node.provider,
                        timestampFormatter: timestampFormatter
                    )
                ))
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

    private func sessionsListApply(
        node: AgentSessionGraphNode,
        to payload: inout [String: Any]
    ) {
        payload["identity_source"] = node.identitySource
        payload["run_id"] = node.runId
        payload["pid"] = node.pid ?? NSNull()
        payload["process_started_at"] = node.processStartedAt ?? NSNull()
        payload["cwd"] = node.cwd ?? NSNull()
        payload["process_state"] = node.processState.rawValue
        payload["session_state"] = node.sessionState.rawValue
        payload["foreground_state"] = node.foregroundState.rawValue
        payload["attention_state"] = node.attentionState.rawValue
        payload["effective_state"] = node.effectiveState.rawValue
        payload["activity"] = sessionsListEncodableJSONObject(node.activity)
        payload["workloads"] = sessionsListEncodableJSONObject(node.workloads)
        payload["restore_authority"] = node.restoreAuthority
        payload["cmux_runtime"] = node.cmuxRuntime
            .map { sessionsListEncodableJSONObject($0) } ?? NSNull()
        payload["state_source"] = node.terminalStateApplied ? "terminal" : "lifecycle"
        payload["terminal_observation"] = node.terminalObservation
            .map { sessionsListEncodableJSONObject($0) } ?? NSNull()
    }

    private func sessionsListProcessPayload(
        node: AgentSessionGraphNode,
        displayName: String,
        timestampFormatter: ISO8601DateFormatter
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "agent": node.provider,
            "agent_display_name": displayName,
            "identity_source": node.identitySource,
            "session_id": NSNull(),
            "run_id": node.runId,
            "workspace_id": node.workspaceId,
            "surface_id": node.surfaceId,
            "store_path": NSNull(),
            "started_at": sessionsListTimestamp(node.startedAt, formatter: timestampFormatter),
            "updated_at": sessionsListTimestamp(node.updatedAt, formatter: timestampFormatter),
            "updated_at_unix": node.updatedAt,
            "cwd": node.cwd ?? NSNull(),
            "transcript_path": NSNull(),
            "pid": node.pid ?? NSNull(),
            "process_started_at": node.processStartedAt ?? NSNull(),
            "runtime_status": NSNull(),
            "agent_lifecycle": NSNull(),
            "process_state": node.processState.rawValue,
            "session_state": node.sessionState.rawValue,
            "foreground_state": node.foregroundState.rawValue,
            "attention_state": node.attentionState.rawValue,
            "effective_state": node.effectiveState.rawValue,
            "activity": sessionsListEncodableJSONObject(node.activity),
            "workloads": sessionsListEncodableJSONObject(node.workloads),
            "restore_authority": false,
            "cmux_runtime": node.cmuxRuntime.map { sessionsListEncodableJSONObject($0) } ?? NSNull(),
            "state_source": "terminal",
            "terminal_observation": node.terminalObservation
                .map { sessionsListEncodableJSONObject($0) } ?? NSNull(),
            "last_prompt_turn_id": NSNull(),
            "active_prompt_turn_id": NSNull(),
            "launch_working_directory": NSNull(),
            "launch_arguments": [],
            "fork_command_available": false,
            "fork_supported": false,
            "active_for_workspace": false,
            "active_for_surface": false,
            "active_workspace_session_id": NSNull(),
            "active_surface_session_id": NSNull(),
            "is_restorable": false,
            "session_home": NSNull(),
            "session_dir": NSNull(),
            "transcript_backed": false,
            "launch_backed": false,
            "default_visible": true,
        ]
        if node.provider == "codex" {
            payload["codex_indexed"] = false
            payload["codex_transcript_found"] = false
            payload["codex_transcript_path"] = NSNull()
        }
        return payload
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
