import CmuxFoundation
import Foundation

extension CMUXCLI {
    private static let agentsTreeDefaultMaximumNodes = 10_000
    static let agentsTreeHardMaximumNodes = 20_000
    private static let agentsTreeHardMaximumDepth = 4_096
    private static let agentsTreeNodeBudgetErrorCode = "agent_graph_node_budget_exceeded"
    private static let agentsTreeRecordSizeErrorCode = "agent_graph_record_too_large"
    private static let agentsTreeHardMaximumRecordBytes = 4 * 1_024 * 1_024

    func runAgentsTreeCommand(
        commandArgs: [String],
        jsonOutput: Bool,
        processEnv: [String: String],
        fileManager: FileManager,
        terminalObservations: [CmuxAgentTerminalObservation]
    ) throws {
        let (agentFilter, remainder0) = try parseAgentsValueOption(commandArgs, name: "--agent", context: .tree)
        let (sessionFilter, remainder1) = try parseAgentsValueOption(remainder0, name: "--session", context: .tree)
        let (workspaceFilter, remainder2) = try parseAgentsValueOption(remainder1, name: "--workspace", context: .tree)
        let (surfaceFilter, remainder3) = try parseAgentsValueOption(remainder2, name: "--surface", context: .tree)
        let (stateDirOverride, remainder4) = try parseAgentsValueOption(remainder3, name: "--state-dir", context: .tree)
        let (relationshipFilter, remainder5) = try parseAgentsValueOption(remainder4, name: "--relation", context: .tree)
        let (stateFilter, remainder6) = try parseAgentsValueOption(remainder5, name: "--state", context: .tree)
        let (activityFilter, remainder7) = try parseAgentsValueOption(remainder6, name: "--activity", context: .tree)
        let (workKindFilter, remainder8) = try parseAgentsValueOption(remainder7, name: "--work-kind", context: .tree)
        let (depthRaw, remainder9) = try parseAgentsValueOption(remainder8, name: "--depth", context: .tree)
        let (maximumNodesRaw, remainder10) = try parseAgentsValueOption(
            remainder9,
            name: "--max-nodes",
            context: .tree
        )

        var localJSONOutput = jsonOutput
        var includeAll = false
        for argument in remainder10 {
            switch argument {
            case "--json": localJSONOutput = true
            case "--all", "--history": includeAll = true
            default:
                throw CLIError(message: String(
                    format: String(localized: "cli.agents.tree.error.unexpectedArgument", defaultValue: "agents tree: unexpected argument '%@'"),
                    argument
                ))
            }
        }
        let maximumDepth: Int
        if let depthRaw {
            guard let parsed = Int(depthRaw), parsed > 0 else {
                throw CLIError(message: String(localized: "cli.agents.tree.error.invalidDepth", defaultValue: "agents tree: --depth must be a positive integer"))
            }
            guard parsed <= Self.agentsTreeHardMaximumDepth else {
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.agents.tree.error.depthTooLarge",
                        defaultValue: "agents tree: --depth must not exceed %lld"
                    ),
                    Self.agentsTreeHardMaximumDepth
                ))
            }
            maximumDepth = parsed
        } else {
            maximumDepth = 64
        }
        let maximumNodes: Int
        if let maximumNodesRaw {
            guard let parsed = Int(maximumNodesRaw),
                  parsed > 0,
                  parsed <= Self.agentsTreeHardMaximumNodes else {
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.agents.tree.error.invalidMaximumNodes",
                        defaultValue: "agents tree: --max-nodes must be an integer from 1 through %lld"
                    ),
                    Self.agentsTreeHardMaximumNodes
                ))
            }
            maximumNodes = parsed
        } else {
            maximumNodes = Self.agentsTreeDefaultMaximumNodes
        }

        let stateDirectory = agentsTreeExpandedPath(
            stateDirOverride
                ?? processEnv["CMUX_AGENT_HOOK_STATE_DIR"]
                ?? URL(fileURLWithPath: processEnv["HOME"] ?? NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent(".cmuxterm", isDirectory: true)
                    .path
        )
        let normalizedAgent: String?
        if let agentFilter {
            let value = agentsNormalizedAgentID(agentFilter)
            guard !value.isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.agents.tree.error.agentRequiresValue",
                    defaultValue: "agents tree: --agent requires a value"
                ))
            }
            normalizedAgent = value
        } else {
            normalizedAgent = nil
        }
        let normalizedSession = agentsTreeNormalized(sessionFilter)?.lowercased()
        let normalizedWorkspace = agentsTreeNormalizedID(workspaceFilter)?.lowercased()
        let normalizedSurface = agentsTreeNormalizedID(surfaceFilter)?.lowercased()
        let normalizedRelationship = agentsTreeNormalized(relationshipFilter)?.lowercased()
        let normalizedState = agentsTreeNormalized(stateFilter)?.lowercased()
        let normalizedActivity = agentsTreeNormalized(activityFilter)?.lowercased()
        let normalizedWorkKind = agentsTreeNormalized(workKindFilter)?.lowercased()
        let queryScope = AgentSessionQueryScope(includeHistory: includeAll, environment: processEnv)
        let includesEndedRecords = includeAll
            || normalizedSession != nil
            || normalizedWorkspace != nil
            || normalizedSurface != nil
            || normalizedState == AgentEffectiveState.ended.rawValue
        if let normalizedRelationship,
           normalizedRelationship != "all",
           AgentSessionRelationship(rawValue: normalizedRelationship) == nil {
            throw CLIError(message: String(
                format: String(localized: "cli.agents.tree.error.unknownRelationship", defaultValue: "agents tree: unknown relationship '%@'"),
                normalizedRelationship
            ))
        }
        if let normalizedState, AgentEffectiveState(rawValue: normalizedState) == nil {
            throw CLIError(message: String(
                format: String(localized: "cli.agents.tree.error.unknownState", defaultValue: "agents tree: unknown state '%@'"),
                normalizedState
            ))
        }
        if let normalizedActivity, AgentActivityState(rawValue: normalizedActivity) == nil {
            throw CLIError(message: String(
                format: String(localized: "cli.agents.tree.error.unknownActivity", defaultValue: "agents tree: unknown activity '%@'"),
                normalizedActivity
            ))
        }
        if let normalizedWorkKind, AgentWorkloadKind(rawValue: normalizedWorkKind) == nil {
            throw CLIError(message: String(
                format: String(localized: "cli.agents.tree.error.unknownWorkKind", defaultValue: "agents tree: unknown workload kind '%@'"),
                normalizedWorkKind
            ))
        }
        let canonicalTerminalObservations = AgentTerminalObservationJoiner.canonicalObservations(
            terminalObservations
        )

        let specifications = [(name: "claude", suffix: "claude")] + Self.agentDefs.map {
            (name: $0.name, suffix: $0.sessionStoreSuffix)
        }
        let providerID = normalizedAgent.flatMap {
            agentSessionProviderID(for: $0, terminalObservations: canonicalTerminalObservations)
        }
        if let normalizedAgent {
            let hasMatchingObservation = canonicalTerminalObservations.contains {
                agentTerminalObservation($0, matchesAnyAgentID: [normalizedAgent])
            }
            guard providerID != nil || hasMatchingObservation else {
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.agents.tree.error.unknownAgent",
                        defaultValue: "agents tree: unknown agent '%@'"
                    ),
                    agentFilter ?? normalizedAgent
                ))
            }
        }
        let selectedSpecifications = if let normalizedAgent {
            specifications.filter { $0.name.lowercased() == (providerID ?? normalizedAgent) }
        } else {
            specifications
        }
        let observationAgentIDs = Set([normalizedAgent, providerID].compactMap { $0 })
        let homeDirectory = agentsTreeExpandedPath(processEnv["HOME"] ?? NSHomeDirectory())
        let claudeTranscriptLookup = SessionsListClaudeTranscriptLookupCache(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        var processStartTimeByPID: [Int: TimeInterval] = [:]
        var missingProcessStartTimePIDs: Set<Int> = []
        var processStateByIdentity: [String: AgentProcessState] = [:]
        let processStateLookup: (Int?, TimeInterval?) -> AgentProcessState = { pid, expectedStartedAt in
            guard let pid, let expectedStartedAt else { return .unknown }
            let identity = "\(pid)\u{1F}\(expectedStartedAt.bitPattern)"
            if let cached = processStateByIdentity[identity] { return cached }
            let actualStartedAt: TimeInterval?
            if let cached = processStartTimeByPID[pid] {
                actualStartedAt = cached
            } else if missingProcessStartTimePIDs.contains(pid) {
                actualStartedAt = nil
            } else if let probed = sessionsListProcessStartTime(for: pid) {
                processStartTimeByPID[pid] = probed
                actualStartedAt = probed
            } else {
                missingProcessStartTimePIDs.insert(pid)
                actualStartedAt = nil
            }
            let state: AgentProcessState = actualStartedAt.map {
                abs($0 - expectedStartedAt) <= 0.001 ? .alive : .exited
            } ?? .exited
            processStateByIdentity[identity] = state
            return state
        }
        let matchingObservations = canonicalTerminalObservations.filter { observation in
            if !observationAgentIDs.isEmpty,
               !agentTerminalObservation(observation, matchesAnyAgentID: observationAgentIDs) {
                return false
            }
            if let normalizedSurface,
               observation.surfaceID.uuidString.lowercased() != normalizedSurface { return false }
            switch queryScope {
            case .history, .legacyUnscoped:
                return true
            case let .currentRuntime(runtimeID):
                return observation.runtimeID == runtimeID
            }
        }
        let observationJoiner = AgentTerminalObservationJoiner()
        let observationsByProcessKey = Dictionary(
            grouping: matchingObservations,
            by: { AgentTerminalObservationJoiner.processKey(observation: $0) }
        )
        let snapshotLoad: AgentHookSessionRegistrySnapshots
        do {
            // Storage admission has its own hard ceiling. The user-facing node
            // budget is enforced below after provider/session/workspace filters,
            // so narrowing a large registry can actually make the query fit.
            snapshotLoad = try AgentHookSessionRegistryBridge.snapshots(
                specifications: selectedSpecifications.map { (provider: $0.name, suffix: $0.suffix) },
                stateDirectory: stateDirectory,
                environment: processEnv,
                fileManager: fileManager
            )
        } catch let failure as AgentHookSessionStoreLoadFailure {
            throw agentsStoreLoadCLIError(failure, context: .tree)
        } catch {
            throw agentsStateUnavailableCLIError(
                stateDirectory: stateDirectory,
                context: .tree
            )
        }
        // Finish the cheap, record-at-a-time pass across every selected
        // provider before allowing any provider-wide compatibility decode.
        // Counts are conservatively additive because node IDs include provider.
        var remainingPreflightNodes = maximumNodes
        for specification in selectedSpecifications {
            guard let snapshot = snapshotLoad.snapshots[specification.name],
                  let visibleCount = try agentsTreeSnapshotVisibleNodeCount(
                    snapshot,
                    provider: specification.name,
                    queryScope: queryScope,
                    includesEndedRecords: includesEndedRecords,
                    normalizedSession: normalizedSession,
                    normalizedWorkspace: normalizedWorkspace,
                    normalizedSurface: normalizedSurface,
                    normalizedState: normalizedState,
                    normalizedActivity: normalizedActivity,
                    normalizedWorkKind: normalizedWorkKind,
                    observationsByProcessKey: observationsByProcessKey,
                    terminalObservations: matchingObservations.filter {
                        $0.sessionProviderID == specification.name
                    },
                    claudeTranscriptLookup: claudeTranscriptLookup,
                    processStateLookup: processStateLookup,
                    maximumNodes: remainingPreflightNodes
                  ) else {
                continue
            }
            guard visibleCount <= remainingPreflightNodes else {
                throw agentsTreeNodeBudgetExceededError(
                    maximumNodes: maximumNodes,
                    observedAtLeast: maximumNodes + 1
                )
            }
            remainingPreflightNodes -= visibleCount
        }
        var nodes: [AgentSessionGraphNode] = []
        var edges: [AgentSessionGraphEdge] = []
        var definitelyVisibleNodeIDs: Set<String> = []
        definitelyVisibleNodeIDs.reserveCapacity(min(maximumNodes, 8_192))
        var nodeIndexByID: [String: Int] = [:]
        nodeIndexByID.reserveCapacity(min(maximumNodes, 8_192))
        let (provisionalMaximumNodes, provisionalMaximumOverflow) = maximumNodes
            .addingReportingOverflow(matchingObservations.count)
        let provisionalNodeLimit = provisionalMaximumOverflow ? Int.max : provisionalMaximumNodes
        var activeSessionBySurface: [String: String] = [:]
        var processedObservationProviders: Set<String> = []
        var storeWarnings = snapshotLoad.warnings
        for specification in selectedSpecifications {
            let url = URL(fileURLWithPath: stateDirectory, isDirectory: true)
                .appendingPathComponent("\(specification.suffix)-hook-sessions.json", isDirectory: false)
            var storeEnvironment = processEnv
            storeEnvironment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDirectory
            storeEnvironment["CMUX_CLAUDE_HOOK_STATE_PATH"] = url.path
            let bridge = AgentHookSessionRegistryBridge(
                provider: specification.name,
                statePath: url.path,
                environment: storeEnvironment,
                fileManager: fileManager
            )
            let store: ClaudeHookSessionStoreFile
            if let snapshot = snapshotLoad.snapshots[specification.name] {
                let load: AgentHookSessionStoreLoadResult
                do {
                    load = try bridge.loadForInspection(snapshot: snapshot)
                } catch let failure as AgentHookSessionStoreLoadFailure {
                    throw agentsStoreLoadCLIError(failure, context: .tree)
                } catch {
                    throw agentsStateUnavailableCLIError(
                        stateDirectory: stateDirectory,
                        context: .tree
                    )
                }
                store = load.store
                if let warning = load.warning { storeWarnings.append(warning) }
            } else {
                store = ClaudeHookSessionStore(
                    processEnv: storeEnvironment,
                    fileManager: fileManager,
                    agentName: specification.name
                ).snapshot()
            }
            guard !store.sessions.isEmpty else { continue }
            let activeSessionIds = Set(store.activeSessionsBySurface.values.map(\.sessionId))
                .union(store.activeSessionsByWorkspace.values.map(\.sessionId))
            for (surfaceID, active) in store.activeSessionsBySurface {
                guard let record = store.sessions[active.sessionId] else { continue }
                for run in agentsTreeRuns(record: record, provider: specification.name) {
                    guard let runtimeID = run.cmuxRuntime(fallingBackTo: record.cmuxRuntime)?.id else {
                        continue
                    }
                    activeSessionBySurface[AgentTerminalObservationJoiner.surfaceKey(
                        provider: specification.name,
                        runtimeID: runtimeID,
                        surfaceID: surfaceID
                    )] = record.sessionId
                }
            }
            let providerObservations = matchingObservations.filter {
                $0.sessionProviderID == specification.name
            }
            processedObservationProviders.insert(specification.name)
            var observationCandidates = AgentTerminalObservationCandidateAccumulator(
                observations: providerObservations,
                activeSessionBySurface: activeSessionBySurface
            )
            var candidateEdgesByNodeID: [String: AgentSessionGraphEdge] = [:]
            let sessionProcessCohort = normalizedSession.map { normalizedSession in
                var matcher = AgentSessionProcessCohortMatcher()
                for record in store.sessions.values
                    where record.sessionId.lowercased() == normalizedSession {
                    for run in agentsTreeRuns(record: record, provider: specification.name) {
                        matcher.insert(provider: specification.name, record: record, run: run)
                    }
                }
                return matcher
            }
            for record in store.sessions.values {
                let runs = agentsTreeRuns(record: record, provider: specification.name)
                if let normalizedSession, record.sessionId.lowercased() != normalizedSession {
                    guard runs.contains(where: { run in
                        sessionProcessCohort?.matches(
                            provider: specification.name,
                            record: record,
                            run: run
                        ) == true
                    }) else { continue }
                }
                if let normalizedSurface, record.surfaceId.lowercased() != normalizedSurface { continue }
                let legacyRecordVisible = activeSessionIds.contains(record.sessionId)
                    || agentHookRecordIsRestorable(
                        agent: specification.name,
                        record: record,
                        claudeTranscriptLookup: claudeTranscriptLookup
                    )
                for run in runs {
                    guard queryScope.includes(
                        recordRuntime: run.identityConflict == true ? nil : record.cmuxRuntime,
                        runRuntime: run.cmuxRuntime,
                        legacyVisible: run.identityConflict != true && legacyRecordVisible
                    ) else { continue }
                    let projection = AgentSessionStateProjection(
                        record: record,
                        run: run,
                        probedProcessState: processStateLookup(run.pid, run.processStartedAt)
                    )
                    guard includesEndedRecords || queryScope.includes(projection: projection) else { continue }
                    let runtime = run.cmuxRuntime(fallingBackTo: record.cmuxRuntime)
                    let node = AgentSessionGraphNode(
                        provider: specification.name,
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
                    let matchingProcessObservations = observationsByProcessKey[
                        AgentTerminalObservationJoiner.processKey(node: node)
                    ] ?? []
                    let canChangeThroughTerminalObservation = matchingProcessObservations.contains {
                        observationJoiner.matches(node, observation: $0)
                    }
                    let matchesLifecycleFilters = (normalizedSession == nil
                        || node.sessionId?.lowercased() == normalizedSession)
                        && agentsTreeNodeMatchesFilters(
                            node,
                            normalizedWorkspace: normalizedWorkspace,
                            normalizedState: normalizedState,
                            normalizedActivity: normalizedActivity,
                            normalizedWorkKind: normalizedWorkKind
                        )
                    let edge = agentsTreeEdge(
                        node: node,
                        run: run,
                        normalizedRelationship: normalizedRelationship
                    )
                    if canChangeThroughTerminalObservation {
                        observationCandidates.insert(node)
                        if !matchesLifecycleFilters,
                           observationCandidates.contains(nodeID: node.nodeId),
                           let edge {
                            candidateEdgesByNodeID[node.nodeId] = edge
                        }
                    }
                    guard matchesLifecycleFilters else { continue }
                    guard try agentsTreeReserveVisibleNode(
                        nodeID: node.nodeId,
                        visibleNodeIDs: &definitelyVisibleNodeIDs,
                        maximumNodes: maximumNodes,
                        provisionalMaximumNodes: provisionalNodeLimit
                    ) else {
                        continue
                    }
                    nodeIndexByID[node.nodeId] = nodes.count
                    nodes.append(node)
                    if let edge { edges.append(edge) }
                }
            }

            var projectedCandidates = observationCandidates.retainedCandidates
            _ = observationJoiner.merge(
                nodes: &projectedCandidates,
                observations: providerObservations,
                activeSessionBySurface: activeSessionBySurface
            )
            for node in projectedCandidates {
                if let existingIndex = nodeIndexByID[node.nodeId] {
                    nodes[existingIndex] = node
                    continue
                }
                guard normalizedSession == nil || node.sessionId?.lowercased() == normalizedSession,
                      agentsTreeNodeMatchesFilters(
                          node,
                          normalizedWorkspace: normalizedWorkspace,
                          normalizedState: normalizedState,
                          normalizedActivity: normalizedActivity,
                          normalizedWorkKind: normalizedWorkKind
                      ),
                      try agentsTreeReserveVisibleNode(
                          nodeID: node.nodeId,
                          visibleNodeIDs: &definitelyVisibleNodeIDs,
                          maximumNodes: maximumNodes,
                          provisionalMaximumNodes: provisionalNodeLimit
                      ) else {
                    continue
                }
                nodeIndexByID[node.nodeId] = nodes.count
                nodes.append(node)
                if let edge = candidateEdgesByNodeID[node.nodeId] { edges.append(edge) }
            }
        }

        var unhandledObservationNodes: [AgentSessionGraphNode] = []
        _ = observationJoiner.merge(
            nodes: &unhandledObservationNodes,
            observations: matchingObservations.filter {
                !processedObservationProviders.contains($0.sessionProviderID)
            },
            activeSessionBySurface: activeSessionBySurface
        )
        for node in unhandledObservationNodes where normalizedSession == nil
            && agentsTreeNodeMatchesFilters(
                node,
                normalizedWorkspace: normalizedWorkspace,
                normalizedState: normalizedState,
                normalizedActivity: normalizedActivity,
                normalizedWorkKind: normalizedWorkKind
            ) {
            guard try agentsTreeReserveVisibleNode(
                nodeID: node.nodeId,
                visibleNodeIDs: &definitelyVisibleNodeIDs,
                maximumNodes: maximumNodes,
                provisionalMaximumNodes: provisionalNodeLimit
            ) else { continue }
            nodes.append(node)
        }
        nodes.removeAll { node in
            if let normalizedSession, node.sessionId?.lowercased() != normalizedSession { return true }
            return !agentsTreeNodeMatchesFilters(
                node,
                normalizedWorkspace: normalizedWorkspace,
                normalizedState: normalizedState,
                normalizedActivity: normalizedActivity,
                normalizedWorkKind: normalizedWorkKind
            )
        }
        if nodes.count > maximumNodes {
            throw agentsTreeNodeBudgetExceededError(
                maximumNodes: maximumNodes,
                observedAtLeast: maximumNodes + 1
            )
        }

        if !edges.isEmpty {
            edges = AgentSessionGraphEdgeSanitizer(
                graphOrdering: agentSessionGraphOrdering
            ).acyclicEdges(nodes: nodes, edges: edges)
            if !edges.isEmpty {
                AgentSubtreeActivityProjector().project(nodes: &nodes, edges: edges)
            }
        }

        nodes.sort(by: agentSessionGraphOrdering.nodePrecedes)
        edges.sort(by: agentSessionGraphOrdering.edgePrecedes)
        let snapshot = AgentSessionGraphSnapshot(
            nodes: nodes,
            edges: edges,
            storeWarnings: storeWarnings.isEmpty ? nil : storeWarnings
        )
        if localJSONOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try AgentStagedOutput().publish { handle in
                var writer = try AgentPrettyJSONStreamWriter(handle: handle)
                try writer.beginArrayField(name: "edges")
                for start in stride(from: 0, to: snapshot.edges.count, by: 512) {
                    let end = min(start + 512, snapshot.edges.count)
                    try writer.writeArrayElements(
                        Array(snapshot.edges[start..<end]),
                        encoder: encoder
                    )
                }
                try writer.endArray()
                try writer.beginArrayField(name: "nodes")
                for start in stride(from: 0, to: snapshot.nodes.count, by: 512) {
                    let end = min(start + 512, snapshot.nodes.count)
                    try writer.writeArrayElements(
                        Array(snapshot.nodes[start..<end]),
                        encoder: encoder
                    )
                }
                try writer.endArray()
                try writer.writeValueField(name: "schema_version", value: snapshot.schemaVersion)
                if let storeWarnings = snapshot.storeWarnings {
                    try writer.writeValueField(
                        name: "store_warnings",
                        value: storeWarnings,
                        encoder: encoder
                    )
                }
                try writer.finish()
            }
        } else {
            agentsWriteStoreWarnings(storeWarnings)
            if snapshot.nodes.isEmpty {
                print(String(localized: "cli.agents.tree.output.noMatches", defaultValue: "No saved agent runs matched."))
            } else {
                for line in AgentTreeTextLineSequence(snapshot: snapshot, maximumDepth: maximumDepth) {
                    print(line)
                }
            }
        }
    }

    private func agentsTreeRuns(
        record: ClaudeHookSessionRecord,
        provider: String
    ) -> [AgentSessionRunRecord] {
        agentSessionRunCanonicalizer.runs(record: record, provider: provider)
    }

    /// Counts raw registry rows one at a time before the compatibility bridge
    /// builds a provider-wide object graph. A malformed authoritative row skips
    /// this optimization so the existing complete-fallback path stays intact.
    private func agentsTreeSnapshotVisibleNodeCount(
        _ snapshot: CmuxAgentSessionRegistry.Snapshot,
        provider: String,
        queryScope: AgentSessionQueryScope,
        includesEndedRecords: Bool,
        normalizedSession: String?,
        normalizedWorkspace: String?,
        normalizedSurface: String?,
        normalizedState: String?,
        normalizedActivity: String?,
        normalizedWorkKind: String?,
        observationsByProcessKey: [String: [CmuxAgentTerminalObservation]],
        terminalObservations: [CmuxAgentTerminalObservation],
        claudeTranscriptLookup: SessionsListClaudeTranscriptLookupCache,
        processStateLookup: (Int?, TimeInterval?) -> AgentProcessState,
        maximumNodes: Int
    ) throws -> Int? {
        let decoder = JSONDecoder()
        var activeSessionIDs: Set<String> = []
        var activeSessionIDBySurface: [String: String] = [:]
        activeSessionIDs.reserveCapacity(snapshot.activeSlots.count)
        for slot in snapshot.activeSlots {
            guard let active = try? decoder.decode(ClaudeHookActiveSessionRecord.self, from: slot.json),
                  active.sessionId == slot.sessionID else {
                return nil
            }
            activeSessionIDs.insert(active.sessionId)
            if slot.scope == .surface {
                activeSessionIDBySurface[slot.scopeID.lowercased()] = active.sessionId
            }
        }

        var visibleNodeIDs: Set<String> = []
        visibleNodeIDs.reserveCapacity(min(maximumNodes + 1, 8_192))
        let observationJoiner = AgentTerminalObservationJoiner()
        var activeSessionBySurface: [String: String] = [:]
        activeSessionBySurface.reserveCapacity(terminalObservations.count)
        for observation in terminalObservations {
            guard let activeSessionID = activeSessionIDBySurface[
                observation.surfaceID.uuidString.lowercased()
            ] else { continue }
            activeSessionBySurface[AgentTerminalObservationJoiner.surfaceKey(
                provider: observation.sessionProviderID,
                runtimeID: observation.runtimeID,
                surfaceID: observation.surfaceID.uuidString
            )] = activeSessionID
        }
        var observationCandidates = AgentTerminalObservationCandidateAccumulator(
            observations: terminalObservations,
            activeSessionBySurface: activeSessionBySurface
        )
        let (provisionalMaximum, provisionalOverflow) = maximumNodes.addingReportingOverflow(
            terminalObservations.count
        )
        let provisionalNodeLimit = provisionalOverflow ? Int.max : provisionalMaximum
        let sessionProcessCohort: AgentSessionProcessCohortMatcher? = if let normalizedSession {
            try agentsTreeSnapshotProcessCohort(
                snapshot,
                provider: provider,
                normalizedSession: normalizedSession
            )
        } else {
            nil
        }
        for stored in snapshot.records {
            if stored.json.count > Self.agentsTreeHardMaximumRecordBytes {
                throw agentsTreeRecordSizeExceededError(
                    provider: provider,
                    sessionID: stored.sessionID,
                    observedBytes: stored.json.count
                )
            }
            guard let record = try? decoder.decode(ClaudeHookSessionRecord.self, from: stored.json),
                  record.sessionId == stored.sessionID else {
                return nil
            }
            if let normalizedSurface, record.surfaceId.lowercased() != normalizedSurface { continue }
            let runs = agentsTreeRuns(record: record, provider: provider)
            if let normalizedSession, record.sessionId.lowercased() != normalizedSession {
                guard runs.contains(where: { run in
                    sessionProcessCohort?.matches(provider: provider, record: record, run: run) == true
                }) else {
                    continue
                }
            }
            let legacyVisible: Bool
            if queryScope == .legacyUnscoped {
                legacyVisible = activeSessionIDs.contains(record.sessionId)
                    || agentHookRecordIsRestorable(
                        agent: provider,
                        record: record,
                        claudeTranscriptLookup: claudeTranscriptLookup
                    )
            } else {
                legacyVisible = false
            }
            for run in runs {
                guard queryScope.includes(
                    recordRuntime: run.identityConflict == true ? nil : record.cmuxRuntime,
                    runRuntime: run.cmuxRuntime,
                    legacyVisible: run.identityConflict != true && legacyVisible
                ) else { continue }
                let projection = AgentSessionStateProjection(
                    record: record,
                    run: run,
                    probedProcessState: processStateLookup(run.pid, run.processStartedAt)
                )
                guard includesEndedRecords || queryScope.includes(projection: projection) else { continue }
                let node = AgentSessionGraphNode(
                    provider: provider,
                    sessionId: record.sessionId,
                    runId: run.runId,
                    pid: run.pid,
                    processStartedAt: run.processStartedAt,
                    cmuxRuntime: run.cmuxRuntime(fallingBackTo: record.cmuxRuntime),
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
                let observations = observationsByProcessKey[
                    AgentTerminalObservationJoiner.processKey(node: node)
                ] ?? []
                let isUncertainObservationCandidate = observations.contains {
                    observationJoiner.matches(node, observation: $0)
                }
                if isUncertainObservationCandidate { observationCandidates.insert(node) }
                // Same-process cohort rows participate in exact-session
                // disambiguation and therefore count toward the inspection
                // budget even though only the requested session is emitted.
                let matchesLifecycleFilters = agentsTreeNodeMatchesFilters(
                    node,
                    normalizedWorkspace: normalizedWorkspace,
                    normalizedState: normalizedState,
                    normalizedActivity: normalizedActivity,
                    normalizedWorkKind: normalizedWorkKind
                )
                guard matchesLifecycleFilters || isUncertainObservationCandidate else {
                    continue
                }
                if matchesLifecycleFilters {
                    visibleNodeIDs.insert(node.nodeId)
                }
                if visibleNodeIDs.count > provisionalNodeLimit { return maximumNodes + 1 }
            }
        }
        var projectedCandidates = observationCandidates.retainedCandidates
        _ = observationJoiner.merge(
            nodes: &projectedCandidates,
            observations: terminalObservations,
            activeSessionBySurface: activeSessionBySurface
        )
        for node in projectedCandidates {
            if node.identitySource == "hook_session" {
                visibleNodeIDs.remove(node.nodeId)
            }
            guard normalizedSession == nil || node.sessionId?.lowercased() == normalizedSession,
                  agentsTreeNodeMatchesFilters(
                            node,
                            normalizedWorkspace: normalizedWorkspace,
                            normalizedState: normalizedState,
                            normalizedActivity: normalizedActivity,
                            normalizedWorkKind: normalizedWorkKind
                  ) else { continue }
            visibleNodeIDs.insert(node.nodeId)
        }
        if visibleNodeIDs.count > maximumNodes { return maximumNodes + 1 }
        return visibleNodeIDs.count
    }

    private func agentsTreeSnapshotProcessCohort(
        _ snapshot: CmuxAgentSessionRegistry.Snapshot,
        provider: String,
        normalizedSession: String
    ) throws -> AgentSessionProcessCohortMatcher? {
        let decoder = JSONDecoder()
        var matcher = AgentSessionProcessCohortMatcher()
        for stored in snapshot.records where stored.sessionID.lowercased() == normalizedSession {
            if stored.json.count > Self.agentsTreeHardMaximumRecordBytes {
                throw agentsTreeRecordSizeExceededError(
                    provider: provider,
                    sessionID: stored.sessionID,
                    observedBytes: stored.json.count
                )
            }
            guard let record = try? decoder.decode(ClaudeHookSessionRecord.self, from: stored.json),
                  record.sessionId == stored.sessionID else {
                return nil
            }
            for run in agentsTreeRuns(record: record, provider: provider) {
                matcher.insert(provider: provider, record: record, run: run)
            }
        }
        return matcher
    }

    private func agentsTreeNodeMatchesFilters(
        _ node: AgentSessionGraphNode,
        normalizedWorkspace: String?,
        normalizedState: String?,
        normalizedActivity: String?,
        normalizedWorkKind: String?
    ) -> Bool {
        if let normalizedWorkspace, node.workspaceId.lowercased() != normalizedWorkspace { return false }
        if let normalizedState, node.effectiveState.rawValue != normalizedState { return false }
        if let normalizedActivity, node.activity.state.rawValue != normalizedActivity { return false }
        if let normalizedWorkKind,
           !node.workloads.contains(where: {
               $0.kind.rawValue == normalizedWorkKind && $0.phase.isActive
           }) {
            return false
        }
        return true
    }

    private func agentsTreeEdge(
        node: AgentSessionGraphNode,
        run: AgentSessionRunRecord,
        normalizedRelationship: String?
    ) -> AgentSessionGraphEdge? {
        guard let relationship = run.relationship,
              normalizedRelationship == nil
                || normalizedRelationship == "all"
                || relationship.rawValue == normalizedRelationship else {
            return nil
        }
        return AgentSessionGraphEdge(
            fromRunId: run.parentRunId,
            fromSessionId: run.parentSessionId,
            toNodeId: node.nodeId,
            toRunId: run.runId,
            relationship: relationship
        )
    }

    private func agentsTreeReserveVisibleNode(
        nodeID: String,
        visibleNodeIDs: inout Set<String>,
        maximumNodes: Int,
        provisionalMaximumNodes: Int
    ) throws -> Bool {
        guard !visibleNodeIDs.contains(nodeID) else { return false }
        guard visibleNodeIDs.count < provisionalMaximumNodes else {
            throw agentsTreeNodeBudgetExceededError(
                maximumNodes: maximumNodes,
                observedAtLeast: maximumNodes + 1
            )
        }
        visibleNodeIDs.insert(nodeID)
        return true
    }

    private func agentsTreeNodeBudgetExceededError(
        maximumNodes: Int,
        observedAtLeast: Int
    ) -> CLIError {
        let message = String(
            format: String(
                localized: "cli.agents.tree.error.nodeBudgetExceeded",
                defaultValue: "agents tree: [%@] graph exceeds --max-nodes %lld (observed at least %lld); narrow the filters or raise --max-nodes, up to %lld"
            ),
            Self.agentsTreeNodeBudgetErrorCode,
            maximumNodes,
            observedAtLeast,
            Self.agentsTreeHardMaximumNodes
        )
        return CLIError(
            message: message,
            v2Code: Self.agentsTreeNodeBudgetErrorCode,
            structuredFields: CLIErrorStructuredFields(
                limit: maximumNodes,
                observedAtLeast: observedAtLeast
            )
        )
    }

    private func agentsTreeRecordSizeExceededError(
        provider: String,
        sessionID: String,
        observedBytes: Int
    ) -> CLIError {
        let message = String(
            format: String(
                localized: "cli.agents.tree.error.recordTooLarge",
                defaultValue: "agents tree: [%@] saved %@ session %@ is %lld bytes; narrow --agent or repair the store (maximum record: %lld bytes)"
            ),
            Self.agentsTreeRecordSizeErrorCode,
            provider,
            sessionID,
            observedBytes,
            Self.agentsTreeHardMaximumRecordBytes
        )
        return CLIError(
            message: message,
            v2Code: Self.agentsTreeRecordSizeErrorCode,
            structuredFields: CLIErrorStructuredFields(
                provider: provider,
                sessionID: sessionID,
                observedBytes: Int64(observedBytes),
                maximumRecordBytes: Self.agentsTreeHardMaximumRecordBytes
            )
        )
    }

    private func agentsTreeExpandedPath(_ value: String) -> String {
        NSString(string: value).expandingTildeInPath
    }

    private func agentsTreeNormalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func agentsTreeNormalizedID(_ value: String?) -> String? {
        guard let value = agentsTreeNormalized(value) else { return nil }
        return value.split(separator: ":", maxSplits: 1).last.map(String.init)
    }
}
