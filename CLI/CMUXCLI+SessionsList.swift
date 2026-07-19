import CmuxFoundation
import Foundation

extension CMUXCLI {
    private typealias CodexSessionListIndex = (indexedSessionIds: Set<String>, transcriptPathBySessionId: [String: String])

    func runSessionsCommand(
        commandArgs rawArgs: [String],
        jsonOutput: Bool,
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        terminalObservations: [CmuxAgentTerminalObservation] = [],
        invocation: AgentsCommandInvocation = .sessions
    ) throws {
        var args = rawArgs
        let commandName = invocation.rawValue
        let listContext: AgentsValueOptionContext = invocation == .agents
            ? .agentsList
            : .sessionsList
        let subcommand = args.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if subcommand == "debug" || subcommand == "list" {
            args.removeFirst()
        } else if subcommand == "help" {
            print(sessionsUsage())
            return
        } else if let subcommand, !subcommand.hasPrefix("-") {
            throw CLIError(message: String(
                format: String(localized: "cli.sessions.error.unknownSubcommand", defaultValue: "Unknown %@ subcommand: %@. Usage: cmux %@ list [options]"),
                commandName,
                subcommand,
                commandName
            ))
        }

        let (agentRaw, rem0) = try parseAgentsValueOption(args, name: "--agent", context: listContext)
        let (sessionRaw, rem1) = try parseAgentsValueOption(rem0, name: "--session", context: listContext)
        let (workspaceRaw, rem2) = try parseAgentsValueOption(rem1, name: "--workspace", context: listContext)
        let (surfaceRaw, rem3) = try parseAgentsValueOption(rem2, name: "--surface", context: listContext)
        let (cwdRaw, rem4) = try parseAgentsValueOption(rem3, name: "--cwd", context: listContext)
        let (stateDirRaw, rem5) = try parseAgentsValueOption(rem4, name: "--state-dir", context: listContext)
        let (codexHomeRaw, rem6) = try parseAgentsValueOption(rem5, name: "--codex-home", context: listContext)
        let (limitRaw, rem7) = try parseAgentsValueOption(rem6, name: "--limit", context: listContext)
        let (stateRaw, rem8) = try parseAgentsValueOption(rem7, name: "--state", context: listContext)
        let (activityRaw, rem9) = try parseAgentsValueOption(rem8, name: "--activity", context: listContext)
        let (workKindRaw, rem10) = try parseAgentsValueOption(rem9, name: "--work-kind", context: listContext)

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
                format: String(localized: "cli.sessions.error.unknownFlag", defaultValue: "%@ list: unknown flag '%@'"),
                commandName,
                unknown
            ))
        }
        if let extra = remaining.first {
            throw CLIError(message: String(
                format: String(localized: "cli.sessions.error.unexpectedArgument", defaultValue: "%@ list: unexpected argument '%@'"),
                commandName,
                extra
            ))
        }

        let limit: Int
        if let limitRaw {
            guard let parsed = Int(limitRaw), parsed > 0 else {
                throw CLIError(message: String(
                    format: String(localized: "cli.sessions.error.invalidLimit", defaultValue: "%@ list: --limit must be a positive integer"),
                    commandName
                ))
            }
            limit = parsed
        } else if includeAll {
            limit = Int.max
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
        let canonicalTerminalObservations = AgentTerminalObservationJoiner.canonicalObservations(
            terminalObservations
        )

        let agentSpecs: [AgentSessionProviderSpecification]
        do {
            agentSpecs = try agentSessionProviderSpecifications(
                stateDirectory: stateDir,
                homeDirectory: homeDirectory,
                requestedAgent: agentRaw,
                processEnv: processEnv,
                fileManager: fileManager
            )
        } catch {
            throw agentsProviderCatalogCLIError(
                error,
                stateDirectory: stateDir,
                context: listContext
            )
        }
        let requestedAgent = agentRaw.map(agentsNormalizedAgentID)
        var providerSelection: AgentSessionProviderSelection?
        let selectedSpecs: [AgentSessionProviderSpecification]
        if let agentRaw, let normalized = requestedAgent {
            guard !normalized.isEmpty else {
                throw CLIError(message: String(
                    format: String(localized: "cli.sessions.error.agentRequiresValue", defaultValue: "%@ list: --agent requires a value"),
                    commandName
                ))
            }
            let selection = agentSessionProviderSelection(
                for: agentRaw,
                availableProviderIDs: agentSpecs.map(\.name),
                terminalObservations: canonicalTerminalObservations
            )
            let hasMatchingObservation = canonicalTerminalObservations.contains {
                agentTerminalObservation(
                    $0,
                    matches: selection,
                    requestedNormalizedID: normalized
                )
            }
            guard selection.providerID != nil || hasMatchingObservation else {
                throw CLIError(message: String(
                    format: String(localized: "cli.sessions.error.unknownAgent", defaultValue: "%@ list: unknown agent '%@'"),
                    commandName,
                    agentRaw
                ))
            }
            selectedSpecs = selection.providerID.map { providerID in
                agentSpecs.filter { $0.name == providerID }
            } ?? []
            providerSelection = selection
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
        // History sorting and non-state filters do not depend on a live PID.
        // Defer sysctl work until after top-K selection in that common path.
        let defersProcessStateProbe = includeAll && stateFilter == nil
        let queryScope = AgentSessionQueryScope(includeHistory: includeAll, environment: processEnv)
        let matchingObservations = canonicalTerminalObservations.compactMap { observation in
            if let providerSelection,
               let requestedAgent,
               !agentTerminalObservation(
                   observation,
                   matches: providerSelection,
                   requestedNormalizedID: requestedAgent
               ) {
                return nil
            }
            if let surfaceFilter,
               observation.surfaceID.uuidString.lowercased() != surfaceFilter { return nil }
            switch queryScope {
            case .history, .legacyUnscoped:
                break
            case let .currentRuntime(runtimeID):
                guard observation.runtimeID == runtimeID else { return nil }
            }
            if let providerSelection {
                return agentTerminalObservation(
                    observation,
                    canonicalizedFor: providerSelection
                )
            }
            return observation
        }
        // The history-only, unfiltered top-K query has no predicate that needs a
        // decoded record. Read K candidates per provider and merge them globally;
        // any provider row ranked below its own K cannot enter the global K.
        let usesBoundedHistoryFastPath = includeAll
            && limit != Int.max
            && sessionFilter == nil
            && workspaceFilter == nil
            && surfaceFilter == nil
            && cwdFilter == nil
            && stateFilter == nil
            && activityFilter == nil
            && workKindFilter == nil
            && matchingObservations.isEmpty
        let observationJoiner = AgentTerminalObservationJoiner()
        let observationsByProcessKey = Dictionary(
            grouping: matchingObservations,
            by: { AgentTerminalObservationJoiner.processKey(observation: $0) }
        )
        let observationsByProvider = Dictionary(
            grouping: matchingObservations,
            by: \.sessionProviderID
        )
        var codexIndexes: [String: CodexSessionListIndex] = [:]
        let claudeTranscriptLookup = SessionsListClaudeTranscriptLookupCache(homeDirectory: homeDirectory)
        var processStartTimeByPID: [Int: TimeInterval] = [:]
        var missingProcessStartTimePIDs: Set<Int> = []
        let processStartTimeLookup: (Int) -> TimeInterval? = { pid in
            if let cached = processStartTimeByPID[pid] { return cached }
            if missingProcessStartTimePIDs.contains(pid) { return nil }
            if let startTime = sessionsListProcessStartTime(for: pid) {
                processStartTimeByPID[pid] = startTime
                return startTime
            }
            missingProcessStartTimePIDs.insert(pid)
            return nil
        }
        var processIdentityByPID: [Int: SessionsListProcessIdentity] = [:]
        var missingProcessIdentityPIDs: Set<Int> = []
        let processIdentityLookup: (Int) -> SessionsListProcessIdentity? = { pid in
            if let cached = processIdentityByPID[pid] { return cached }
            if missingProcessIdentityPIDs.contains(pid) { return nil }
            guard let startTime = processStartTimeLookup(pid),
                  let identity = sessionsListProcessIdentity(
                    for: pid,
                    probedKernelStartTime: startTime
                  ) else {
                missingProcessIdentityPIDs.insert(pid)
                return nil
            }
            processIdentityByPID[pid] = identity
            return identity
        }
        var processExistenceByPID: [Int: Bool] = [:]
        var probedProcessExistencePIDs: Set<Int> = []
        let processExistenceLookup: (Int?) -> Bool? = { pid in
            guard let pid, pid > 0 else { return nil }
            if probedProcessExistencePIDs.contains(pid) { return processExistenceByPID[pid] }
            probedProcessExistencePIDs.insert(pid)
            let exists = sessionsListStoredPIDExists(pid)
            if let exists { processExistenceByPID[pid] = exists }
            return exists
        }
        var entries = SessionListEntryAccumulator(limit: limit)
        var activeSessionBySurface: [String: String] = [:]
        var processedObservationProviders: Set<String> = []
        var stores: [[String: Any]] = []
        var storeWarnings: [AgentHookSessionStoreLoadWarning] = []

        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let snapshotLoad: AgentHookSessionRegistrySnapshots
        do {
            if usesBoundedHistoryFastPath {
                snapshotLoad = try AgentHookSessionRegistryBridge.boundedRecentSnapshotsForList(
                    specifications: selectedSpecs.map {
                        (provider: $0.name, suffix: $0.sessionStoreSuffix)
                    },
                    stateDirectory: stateDir,
                    environment: processEnv,
                    fileManager: fileManager,
                    maximumRecordsPerProvider: limit
                )
            } else {
                snapshotLoad = try AgentHookSessionRegistryBridge.snapshots(
                    specifications: selectedSpecs.map {
                        (provider: $0.name, suffix: $0.sessionStoreSuffix)
                    },
                    stateDirectory: stateDir,
                    environment: processEnv,
                    fileManager: fileManager
                )
            }
        } catch let failure as AgentHookSessionStoreLoadFailure {
            throw agentsStoreLoadCLIError(failure, context: listContext)
        } catch {
            throw agentsStateUnavailableCLIError(
                stateDirectory: stateDir,
                context: listContext
            )
        }
        storeWarnings.append(contentsOf: snapshotLoad.warnings)
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
            let store: ClaudeHookSessionStoreFile
            var boundedLoadUsedLegacyFallback = false
            if let snapshot = snapshotLoad.snapshots[spec.name] {
                let load: AgentHookSessionStoreLoadResult
                do {
                    if usesBoundedHistoryFastPath {
                        load = try bridge.loadBoundedForInspection(
                            snapshot: snapshot,
                            authoritativeValidationFailed: snapshotLoad
                                .boundedValidationFailures.contains(spec.name)
                        )
                    } else {
                        load = try bridge.loadForInspection(snapshot: snapshot)
                    }
                } catch let failure as AgentHookSessionStoreLoadFailure {
                    throw agentsStoreLoadCLIError(failure, context: listContext)
                } catch {
                    throw agentsStateUnavailableCLIError(
                        stateDirectory: stateDir,
                        context: listContext
                    )
                }
                store = load.store
                boundedLoadUsedLegacyFallback = usesBoundedHistoryFastPath
                    && load.warning?.fallback == .legacy
                if let warning = load.warning { storeWarnings.append(warning) }
            } else {
                store = ClaudeHookSessionStore(
                    processEnv: storeEnvironment,
                    fileManager: fileManager,
                    agentName: spec.name
                ).snapshot()
            }
            let totalProviderSessionCount = boundedLoadUsedLegacyFallback
                ? store.sessions.count
                : snapshotLoad.totalRecordCounts[spec.name] ?? store.sessions.count
            var storePayload: [String: Any] = [
                "agent": spec.name,
                "path": storePath,
                "exists": fileManager.fileExists(atPath: storePath) || totalProviderSessionCount > 0
            ]

            storePayload["session_count"] = totalProviderSessionCount
            stores.append(storePayload)

            let sessionProcessCohort = sessionFilter.map { sessionFilter in
                var matcher = AgentSessionProcessCohortMatcher()
                for record in store.sessions.values
                    where record.sessionId.lowercased() == sessionFilter {
                    matcher.insert(
                        provider: spec.name,
                        record: record,
                        run: sessionsListProjectedRun(record: record, provider: spec.name)
                    )
                }
                return matcher
            }

            for record in store.sessions.values {
                let run = sessionsListProjectedRun(record: record, provider: spec.name)
                guard store.activeSessionsBySurface[record.surfaceId]?.sessionId == record.sessionId,
                      let runtimeID = run.cmuxRuntime(fallingBackTo: record.cmuxRuntime)?.id else {
                    continue
                }
                activeSessionBySurface[AgentTerminalObservationJoiner.surfaceKey(
                    provider: spec.name,
                    runtimeID: runtimeID,
                    surfaceID: record.surfaceId
                )] = record.sessionId
            }

            let providerObservations = observationsByProvider[spec.name] ?? []
            processedObservationProviders.insert(spec.name)
            let observationProjection: (
                nodesByID: [String: AgentSessionGraphNode],
                processNodes: [AgentSessionGraphNode]
            ) = {
                guard !providerObservations.isEmpty else { return ([:], []) }
                var candidateAccumulator = AgentTerminalObservationCandidateAccumulator(
                    observations: providerObservations,
                    activeSessionBySurface: activeSessionBySurface
                )
                for rawRecord in store.sessions.values {
                    let run = sessionsListProjectedRun(record: rawRecord, provider: spec.name)
                    guard queryScope.includes(
                        recordRuntime: run.identityConflict == true ? nil : rawRecord.cmuxRuntime,
                        runRuntime: run.cmuxRuntime,
                        legacyVisible: run.identityConflict != true
                    ) else { continue }
                    let record = rawRecord
                    if let sessionFilter, record.sessionId.lowercased() != sessionFilter {
                        guard sessionProcessCohort?.matches(
                            provider: spec.name,
                            record: record,
                            run: run
                        ) == true else {
                            continue
                        }
                    }
                    guard surfaceFilter == nil || record.surfaceId.lowercased() == surfaceFilter else {
                        continue
                    }
                    let runtime = run.cmuxRuntime(fallingBackTo: record.cmuxRuntime)
                    guard let runtimeID = runtime?.id,
                          let pid = run.pid,
                          let processStartedAt = run.processStartedAt else {
                        continue
                    }
                    let surfaceKey = AgentTerminalObservationJoiner.surfaceKey(
                        provider: spec.name,
                        runtimeID: runtimeID,
                        surfaceID: record.surfaceId
                    )
                    let processKey = "\(surfaceKey)\u{1F}\(pid)"
                    let observations = observationsByProcessKey[processKey] ?? []
                    guard observations.contains(where: { observation in
                        observation.sessionProviderID == spec.name
                            && observation.runtimeID == runtimeID
                            && observation.surfaceID.uuidString.lowercased()
                                == record.surfaceId.lowercased()
                            && Int(observation.pid) == pid
                            && abs(
                                TimeInterval(observation.processStartSeconds)
                                    + TimeInterval(observation.processStartMicroseconds) / 1_000_000
                                    - processStartedAt
                            ) <= 0.001
                    }) else {
                        continue
                    }
                    let probedProcessState: AgentProcessState?
                    if run.identityConflict == true {
                        probedProcessState = .unknown
                    } else if let pid = run.pid, let expectedStartedAt = run.processStartedAt {
                        probedProcessState = processStartTimeLookup(pid).map {
                            abs($0 - expectedStartedAt) <= 0.001 ? .alive : .exited
                        } ?? .exited
                    } else {
                        probedProcessState = nil
                    }
                    let projection = AgentSessionStateProjection(
                        record: record,
                        run: run,
                        probedProcessState: probedProcessState
                    )
                    guard includesEndedRecords || queryScope.includes(projection: projection) else {
                        continue
                    }
                    let workspaceActive = store.activeSessionsByWorkspace[record.workspaceId]
                    let surfaceActive = store.activeSessionsBySurface[record.surfaceId]
                    let activeForWorkspace = workspaceActive?.sessionId == record.sessionId
                    let activeForSurface = surfaceActive?.sessionId == record.sessionId
                    let legacyRecordRestorable: Bool
                    if queryScope == .legacyUnscoped,
                       run.identityConflict != true,
                       !activeForWorkspace,
                       !activeForSurface {
                        legacyRecordRestorable = agentHookRunIsRestorable(
                            agent: spec.name,
                            record: record,
                            run: run,
                            claudeTranscriptLookup: claudeTranscriptLookup
                        )
                    } else {
                        legacyRecordRestorable = false
                    }
                    let defaultVisible = queryScope.includes(
                        recordRuntime: run.identityConflict == true ? nil : record.cmuxRuntime,
                        runRuntime: run.cmuxRuntime,
                        legacyVisible: run.identityConflict != true
                            && (activeForWorkspace || activeForSurface || legacyRecordRestorable)
                    )
                    guard includeAll || hasIdentityFilter
                            || stateFilter == AgentEffectiveState.ended.rawValue
                            || defaultVisible else {
                        continue
                    }
                    let node = AgentSessionGraphNode(
                        provider: spec.name,
                        sessionId: record.sessionId,
                        runId: run.runId,
                        pid: run.pid,
                        processStartedAt: run.processStartedAt,
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
                        restoreAuthority: run.restoreAuthority,
                        startedAt: run.startedAt,
                        updatedAt: run.updatedAt,
                        endedAt: run.endedAt
                    )
                    candidateAccumulator.insert(node)
                }
                var candidates = candidateAccumulator.retainedCandidates
                observationJoiner.merge(
                    nodes: &candidates,
                    observations: providerObservations,
                    activeSessionBySurface: activeSessionBySurface
                )
                var nodesByID: [String: AgentSessionGraphNode] = [:]
                var processNodes: [AgentSessionGraphNode] = []
                nodesByID.reserveCapacity(providerObservations.count)
                processNodes.reserveCapacity(providerObservations.count)
                for node in candidates {
                    if node.identitySource == "terminal_process" {
                        processNodes.append(node)
                    } else if node.terminalObservation != nil {
                        nodesByID[node.nodeId] = node
                    }
                }
                return (nodesByID, processNodes)
            }()

            for rawRecord in store.sessions.values {
                let projectedRun = sessionsListProjectedRun(record: rawRecord, provider: spec.name)
                guard queryScope.includes(
                    recordRuntime: projectedRun.identityConflict == true ? nil : rawRecord.cmuxRuntime,
                    runRuntime: projectedRun.cmuxRuntime,
                    legacyVisible: projectedRun.identityConflict != true
                ) else { continue }
                let record = rawRecord
                if let sessionFilter, record.sessionId.lowercased() != sessionFilter {
                    guard sessionProcessCohort?.matches(
                        provider: spec.name,
                        record: record,
                        run: projectedRun
                    ) == true else {
                        continue
                    }
                }
                guard surfaceFilter == nil || record.surfaceId.lowercased() == surfaceFilter else { continue }
                let probedProcessState: AgentProcessState?
                if projectedRun.identityConflict == true || defersProcessStateProbe {
                    // Supplying `.unknown` prevents the projection from probing
                    // through its compatibility fallback.
                    probedProcessState = .unknown
                } else if let pid = projectedRun.pid,
                   let expectedStartedAt = projectedRun.processStartedAt {
                    probedProcessState = processStartTimeLookup(pid).map {
                        abs($0 - expectedStartedAt) <= 0.001 ? .alive : .exited
                    } ?? .exited
                } else {
                    probedProcessState = nil
                }
                let projection = AgentSessionStateProjection(
                    record: record,
                    run: projectedRun,
                    probedProcessState: probedProcessState
                )
                guard includesEndedRecords || queryScope.includes(projection: projection) else { continue }
                let workspaceActive = store.activeSessionsByWorkspace[record.workspaceId]
                let surfaceActive = store.activeSessionsBySurface[record.surfaceId]
                let activeForWorkspace = workspaceActive?.sessionId == record.sessionId
                    || workspaceActive?.sessionId == rawRecord.sessionId
                let activeForSurface = surfaceActive?.sessionId == record.sessionId
                    || surfaceActive?.sessionId == rawRecord.sessionId

                let runtime = projectedRun.cmuxRuntime(fallingBackTo: record.cmuxRuntime)
                if activeForSurface, let runtimeID = runtime?.id {
                    activeSessionBySurface[AgentTerminalObservationJoiner.surfaceKey(
                        provider: spec.name,
                        runtimeID: runtimeID,
                        surfaceID: record.surfaceId
                    )] = record.sessionId
                }

                let legacyRecordRestorable: Bool
                if queryScope == .legacyUnscoped,
                   projectedRun.identityConflict != true,
                   !activeForWorkspace,
                   !activeForSurface {
                    legacyRecordRestorable = agentHookRunIsRestorable(
                        agent: spec.name,
                        record: record,
                        run: projectedRun,
                        claudeTranscriptLookup: claudeTranscriptLookup
                    )
                } else {
                    legacyRecordRestorable = false
                }
                let legacyDefaultVisible = activeForWorkspace
                    || activeForSurface
                    || legacyRecordRestorable
                let defaultVisible = queryScope.includes(
                    recordRuntime: projectedRun.identityConflict == true ? nil : record.cmuxRuntime,
                    runRuntime: projectedRun.cmuxRuntime,
                    legacyVisible: projectedRun.identityConflict != true && legacyDefaultVisible
                )
                guard includeAll || hasIdentityFilter
                        || stateFilter == AgentEffectiveState.ended.rawValue
                        || defaultVisible else {
                    continue
                }

                let enrichment: SessionListEntryAccumulator.Enrichment = { [self] payload in
                    if defersProcessStateProbe,
                       projectedRun.identityConflict != true,
                       payload["state_source"] as? String != "terminal" {
                        let retainedProcessState: AgentProcessState?
                        if let pid = projectedRun.pid,
                           let expectedStartedAt = projectedRun.processStartedAt {
                            retainedProcessState = processStartTimeLookup(pid).map {
                                abs($0 - expectedStartedAt) <= 0.001 ? .alive : .exited
                            } ?? .exited
                        } else {
                            retainedProcessState = nil
                        }
                        let retainedProjection = AgentSessionStateProjection(
                            record: record,
                            run: projectedRun,
                            probedProcessState: retainedProcessState
                        )
                        self.sessionsListApply(projection: retainedProjection, to: &payload)
                    }
                    payload.merge(
                        sessionsListForkDiagnostics(
                            agent: spec.name,
                            record: record,
                            projectedRunRestoreAuthority: projectedRun.restoreAuthority,
                            claudeTranscriptLookup: claudeTranscriptLookup,
                            processIdentityLookup: processIdentityLookup,
                            processExistenceLookup: processExistenceLookup
                        ),
                        uniquingKeysWith: { _, new in new }
                    )

                    var transcriptBacked = false
                    if spec.name == "codex" {
                        let codexHome = sessionsListExpandedPath(
                            sessionsListNormalized(record.launchCommand?.environment?["CODEX_HOME"])
                                ?? defaultCodexHome
                        )
                        let index = codexIndexes[codexHome] ?? buildCodexDebugIndex(
                            codexHome: codexHome,
                            fileManager: fileManager
                        )
                        codexIndexes[codexHome] = index
                        let transcriptPath = index.transcriptPathBySessionId[record.sessionId]
                        let savedTranscriptPath = sessionsListNormalized(record.transcriptPath)
                        let expandedSavedTranscriptPath = savedTranscriptPath.map {
                            self.sessionsListExpandedPath($0)
                        }
                        payload["session_home"] = codexHome
                        payload["session_dir"] = URL(fileURLWithPath: codexHome, isDirectory: true)
                            .appendingPathComponent("sessions", isDirectory: true)
                            .path
                        payload["codex_indexed"] = index.indexedSessionIds.contains(record.sessionId)
                        payload["codex_transcript_found"] = transcriptPath != nil
                            || expandedSavedTranscriptPath.map {
                                fileManager.fileExists(atPath: $0)
                            } == true
                        payload["codex_transcript_path"] = transcriptPath
                            ?? expandedSavedTranscriptPath
                            ?? NSNull()
                        transcriptBacked = payload["codex_transcript_found"] as? Bool == true
                    } else if spec.name == "claude" {
                        if let envKey = spec.configDirEnvOverride,
                           let value = sessionsListNormalized(record.launchCommand?.environment?[envKey]) {
                            payload["session_home"] = sessionsListExpandedPath(value)
                            payload["session_dir"] = sessionsListExpandedPath(value)
                        } else {
                            payload["session_home"] = NSNull()
                            payload["session_dir"] = NSNull()
                        }
                        transcriptBacked = sessionsListClaudeHasExactTranscript(
                            record: record,
                            lookup: claudeTranscriptLookup
                        )
                    } else if let envKey = spec.configDirEnvOverride,
                              let value = sessionsListNormalized(record.launchCommand?.environment?[envKey]) {
                        payload["session_home"] = sessionsListExpandedPath(value)
                        payload["session_dir"] = sessionsListExpandedPath(value)
                        if let transcriptPath = sessionsListNormalized(record.transcriptPath) {
                            transcriptBacked = fileManager.fileExists(
                                atPath: sessionsListExpandedPath(transcriptPath)
                            )
                        }
                    } else {
                        payload["session_home"] = NSNull()
                        payload["session_dir"] = NSNull()
                        if let transcriptPath = sessionsListNormalized(record.transcriptPath) {
                            transcriptBacked = fileManager.fileExists(
                                atPath: sessionsListExpandedPath(transcriptPath)
                            )
                        }
                    }
                    payload["transcript_backed"] = transcriptBacked
                    payload["launch_backed"] = record.launchCommand != nil
                        && agentHookSessionHasDurableResumeEvidence(
                            kind: spec.name,
                            launchCommand: record.launchCommand,
                            transcriptPath: record.transcriptPath
                        )
                }

                let node = AgentSessionGraphNode(
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
                )
                let projectedNode = observationProjection.nodesByID[node.nodeId] ?? node
                guard sessionsListNodeMatchesFilters(
                    node: projectedNode,
                    launchWorkingDirectory: record.launchCommand?.workingDirectory,
                    sessionFilter: sessionFilter,
                    workspaceFilter: workspaceFilter,
                    cwdFilter: cwdFilter,
                    stateFilter: stateFilter,
                    activityFilter: activityFilter,
                    workKindFilter: workKindFilter
                ) else { continue }
                let activeWorkspaceSessionID = workspaceActive?.sessionId
                let activeSurfaceSessionID = surfaceActive?.sessionId
                entries.insert(
                    updatedAt: node.updatedAt,
                    sortValues: sessionsListSortValues(
                        node: projectedNode,
                        sessionID: record.sessionId,
                        agent: spec.name,
                        surfaceID: record.surfaceId
                    ),
                    payloadFactory: { [self] in
                        var payload: [String: Any] = [
                            "agent": spec.name,
                            "agent_display_name": spec.displayName,
                            "session_id": record.sessionId,
                            "workspace_id": record.workspaceId,
                            "surface_id": record.surfaceId,
                            "store_path": storePath,
                            "started_at": sessionsListTimestamp(
                                record.startedAt,
                                formatter: timestampFormatter
                            ),
                            "updated_at": sessionsListTimestamp(
                                record.updatedAt,
                                formatter: timestampFormatter
                            ),
                            "updated_at_unix": record.updatedAt,
                        ]
                        payload["cwd"] = record.cwd ?? NSNull()
                        payload["transcript_path"] = record.transcriptPath ?? NSNull()
                        payload["pid"] = record.pid ?? NSNull()
                        payload["runtime_status"] = record.runtimeStatus?.rawValue ?? NSNull()
                        payload["agent_lifecycle"] = record.agentLifecycle?.rawValue ?? NSNull()
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
                        payload["cmux_runtime"] = runtime.map {
                            sessionsListEncodableJSONObject($0)
                        } ?? NSNull()
                        payload["last_prompt_turn_id"] = record.lastPromptTurnId ?? NSNull()
                        payload["active_prompt_turn_id"] = record.activePromptTurnId ?? NSNull()
                        payload["launch_working_directory"] = record.launchCommand?.workingDirectory
                            ?? NSNull()
                        payload["launch_arguments"] = record.launchCommand?.arguments ?? []
                        payload["active_for_workspace"] = activeForWorkspace
                        payload["active_for_surface"] = activeForSurface
                        payload["active_workspace_session_id"] = activeWorkspaceSessionID ?? NSNull()
                        payload["active_surface_session_id"] = activeSurfaceSessionID ?? NSNull()
                        payload["is_restorable"] = record.isRestorable ?? NSNull()
                        payload["default_visible"] = defaultVisible
                        sessionsListApply(node: projectedNode, to: &payload)
                        enrichment(&payload)
                        return payload
                    }
                )
            }
            for node in observationProjection.processNodes {
                guard sessionsListNodeMatchesFilters(
                    node: node,
                    launchWorkingDirectory: nil,
                    sessionFilter: sessionFilter,
                    workspaceFilter: workspaceFilter,
                    cwdFilter: cwdFilter,
                    stateFilter: stateFilter,
                    activityFilter: activityFilter,
                    workKindFilter: workKindFilter
                ) else { continue }
                entries.insert(
                    updatedAt: node.updatedAt,
                    sortValues: sessionsListSortValues(
                        node: node,
                        sessionID: nil,
                        agent: node.provider,
                        surfaceID: node.surfaceId
                    ),
                    payloadFactory: { [self] in
                        sessionsListProcessPayload(
                            node: node,
                            displayName: spec.displayName,
                            timestampFormatter: timestampFormatter
                        )
                    }
                )
            }
            if usesBoundedHistoryFastPath {
                entries.addUnmaterializedMatches(
                    max(0, totalProviderSessionCount - store.sessions.count)
                )
            }
        }
        let displayNameByProvider = Dictionary(
            selectedSpecs.map { ($0.name, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        var unhandledObservationNodes: [AgentSessionGraphNode] = []
        observationJoiner.merge(
            nodes: &unhandledObservationNodes,
            observations: matchingObservations.filter {
                !processedObservationProviders.contains($0.sessionProviderID)
            },
            activeSessionBySurface: activeSessionBySurface
        )
        for node in unhandledObservationNodes {
            guard sessionsListNodeMatchesFilters(
                node: node,
                launchWorkingDirectory: nil,
                sessionFilter: sessionFilter,
                workspaceFilter: workspaceFilter,
                cwdFilter: cwdFilter,
                stateFilter: stateFilter,
                activityFilter: activityFilter,
                workKindFilter: workKindFilter
            ) else { continue }
            let displayName = displayNameByProvider[node.provider] ?? node.provider
            entries.insert(
                updatedAt: node.updatedAt,
                sortValues: sessionsListSortValues(
                    node: node,
                    sessionID: nil,
                    agent: node.provider,
                    surfaceID: node.surfaceId
                ),
                payloadFactory: { [self] in
                    sessionsListProcessPayload(
                        node: node,
                        displayName: displayName,
                        timestampFormatter: timestampFormatter
                    )
                }
            )
        }

        if localJSONOutput {
            try AgentStagedOutput().publish(build: { handle in
                var writer = try AgentPrettyJSONStreamWriter(handle: handle)
                try writer.writeValueField(name: "schema_version", value: 2)
                try writer.writeValueField(name: "default_codex_home", value: defaultCodexHome)
                try writer.writeValueField(
                    name: "limit",
                    value: limit == Int.max ? NSNull() : NSNumber(value: limit)
                )
                try writer.beginArrayField(name: "sessions")
                var payloadBatch: [[String: Any]] = []
                payloadBatch.reserveCapacity(512)
                try entries.forEachSortedPayload { payload in
                    payloadBatch.append(payload)
                    if payloadBatch.count == 512 {
                        try writer.writeArrayElements(payloadBatch)
                        payloadBatch.removeAll(keepingCapacity: true)
                    }
                }
                if !payloadBatch.isEmpty {
                    try writer.writeArrayElements(payloadBatch)
                }
                try writer.endArray()
                try writer.writeValueField(name: "state_dir", value: stateDir)
                if !storeWarnings.isEmpty {
                    try writer.writeValueField(
                        name: "store_warnings",
                        value: storeWarnings.map(sessionsListEncodableJSONObject)
                    )
                }
                try writer.writeValueField(name: "stores", value: stores)
                try writer.writeValueField(name: "total_matches", value: entries.totalCount)
                try writer.finish()
            }, publishChunk: cliWriteStdout)
            return
        }

        agentsWriteStoreWarnings(storeWarnings)
        if entries.retainedCount == 0 {
            print(String(localized: "cli.sessions.output.noMatches", defaultValue: "No saved agent sessions matched."))
            print("state_dir=\(stateDir)")
            return
        }

        entries.forEachSortedPayload { payload in
            print(renderSessionListLine(payload))
        }
        if entries.totalCount > entries.retainedCount {
            let moreFormat = if includeAll {
                String(
                    localized: "cli.sessions.output.moreLimitedAll",
                    defaultValue: "... %lld more. Raise --limit <n>."
                )
            } else {
                String(
                    localized: "cli.sessions.output.more",
                    defaultValue: "... %lld more. Pass --all or --limit <n>."
                )
            }
            print(String(
                format: moreFormat,
                entries.totalCount - entries.retainedCount
            ))
        }
    }

    private func sessionsListProjectedRun(
        record: ClaudeHookSessionRecord,
        provider: String
    ) -> AgentSessionRunRecord {
        agentSessionRunCanonicalizer.projectedRun(record: record, provider: provider)
    }

    private func sessionsListNodeMatchesFilters(
        node: AgentSessionGraphNode,
        launchWorkingDirectory: String?,
        sessionFilter: String?,
        workspaceFilter: String?,
        cwdFilter: String?,
        stateFilter: String?,
        activityFilter: String?,
        workKindFilter: String?
    ) -> Bool {
        if let sessionFilter, node.sessionId?.lowercased() != sessionFilter { return false }
        if let workspaceFilter, node.workspaceId.lowercased() != workspaceFilter { return false }
        if let cwdFilter {
            let cwd = (node.cwd ?? "").lowercased()
            let launchCWD = (launchWorkingDirectory ?? "").lowercased()
            if !cwd.contains(cwdFilter) && !launchCWD.contains(cwdFilter) { return false }
        }
        if let stateFilter, node.effectiveState.rawValue != stateFilter { return false }
        if let activityFilter, node.activity.state.rawValue != activityFilter { return false }
        if let workKindFilter,
           !node.workloads.contains(where: {
               $0.kind.rawValue == workKindFilter && $0.phase.isActive
           }) {
            return false
        }
        return true
    }

    private func sessionsListSortValues(
        node: AgentSessionGraphNode,
        sessionID: String?,
        agent: String,
        surfaceID: String
    ) -> SessionListEntryAccumulator.SortValues {
        SessionListEntryAccumulator.SortValues(
            sessionID: sessionID,
            agent: agent,
            runID: node.runId,
            workspaceID: node.workspaceId,
            surfaceID: surfaceID,
            identitySource: node.identitySource,
            pid: node.pid,
            processStartedAt: node.processStartedAt
        )
    }

    private func sessionsListApply(
        node: AgentSessionGraphNode,
        to payload: inout [String: Any]
    ) {
        payload["identity_source"] = node.identitySource
        payload["run_id"] = node.runId
        payload["pid"] = node.pid ?? NSNull()
        payload["process_started_at"] = node.processStartedAt ?? NSNull()
        payload["workspace_id"] = node.workspaceId
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

    private func sessionsListApply(
        projection: AgentSessionStateProjection,
        to payload: inout [String: Any]
    ) {
        payload["process_state"] = projection.process.rawValue
        payload["session_state"] = projection.session.rawValue
        payload["foreground_state"] = projection.foreground.rawValue
        payload["attention_state"] = projection.attention.rawValue
        payload["effective_state"] = projection.effective.rawValue
        payload["activity"] = sessionsListEncodableJSONObject(projection.activity)
        payload["workloads"] = sessionsListEncodableJSONObject(
            projection.workloads.map(AgentWorkloadSnapshot.init)
        )
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

    private func buildCodexDebugIndex(
        codexHome: String,
        fileManager: FileManager
    ) -> CodexSessionListIndex {
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
