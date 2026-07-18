import CmuxFoundation
import Foundation

extension CMUXCLI {
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

        var localJSONOutput = jsonOutput
        var includeAll = false
        for argument in remainder9 {
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
            maximumDepth = parsed
        } else {
            maximumDepth = 64
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
        let snapshots = AgentHookSessionRegistryBridge.snapshots(
            specifications: selectedSpecifications.map { (provider: $0.name, suffix: $0.suffix) },
            stateDirectory: stateDirectory,
            environment: processEnv,
            fileManager: fileManager
        )
        var nodes: [AgentSessionGraphNode] = []
        var edges: [AgentSessionGraphEdge] = []
        var activeSessionBySurface: [String: String] = [:]
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
            let store = snapshots?[specification.name].map { bridge.load(snapshot: $0) }
                ?? ClaudeHookSessionStore(
                    processEnv: storeEnvironment,
                    fileManager: fileManager,
                    agentName: specification.name
                ).snapshot()
            guard !store.sessions.isEmpty else { continue }
            let activeSessionIds = Set(store.activeSessionsBySurface.values.map(\.sessionId))
                .union(store.activeSessionsByWorkspace.values.map(\.sessionId))
            for record in store.sessions.values {
                if let normalizedSession, record.sessionId.lowercased() != normalizedSession { continue }
                if let normalizedWorkspace, record.workspaceId.lowercased() != normalizedWorkspace { continue }
                if let normalizedSurface, record.surfaceId.lowercased() != normalizedSurface { continue }
                let runs = agentsTreeRuns(record: record, provider: specification.name)
                let legacyRecordVisible = activeSessionIds.contains(record.sessionId)
                    || agentHookRecordIsRestorable(
                        agent: specification.name,
                        record: record,
                        claudeTranscriptLookup: claudeTranscriptLookup
                    )
                for run in runs {
                    guard queryScope.includes(
                        recordRuntime: record.cmuxRuntime,
                        runRuntime: run.cmuxRuntime,
                        legacyVisible: legacyRecordVisible
                    ) else { continue }
                    let projection = AgentSessionStateProjection(record: record, run: run)
                    guard includesEndedRecords || queryScope.includes(projection: projection) else { continue }
                    let runtime = run.cmuxRuntime ?? record.cmuxRuntime
                    if store.activeSessionsBySurface[record.surfaceId]?.sessionId == record.sessionId,
                       let runtimeID = runtime?.id {
                        activeSessionBySurface[AgentTerminalObservationJoiner.surfaceKey(
                            provider: specification.name,
                            runtimeID: runtimeID,
                            surfaceID: record.surfaceId
                        )] = record.sessionId
                    }
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
                    nodes.append(node)
                    if let relationship = run.relationship,
                       normalizedRelationship == nil || normalizedRelationship == "all" || relationship.rawValue == normalizedRelationship {
                        edges.append(AgentSessionGraphEdge(
                            fromRunId: run.parentRunId,
                            fromSessionId: run.parentSessionId,
                            toNodeId: node.nodeId,
                            toRunId: run.runId,
                            relationship: relationship
                        ))
                    }
                }
            }
        }

        let matchingObservations = canonicalTerminalObservations.filter { observation in
            if !observationAgentIDs.isEmpty,
               !agentTerminalObservation(observation, matchesAnyAgentID: observationAgentIDs) {
                return false
            }
            if let normalizedWorkspace,
               observation.workspaceID.uuidString.lowercased() != normalizedWorkspace { return false }
            if let normalizedSurface,
               observation.surfaceID.uuidString.lowercased() != normalizedSurface { return false }
            switch queryScope {
            case .history, .legacyUnscoped:
                return true
            case let .currentRuntime(runtimeID):
                return observation.runtimeID == runtimeID
            }
        }
        nodes = AgentTerminalObservationJoiner().merge(
            nodes: nodes,
            observations: matchingObservations,
            activeSessionBySurface: activeSessionBySurface
        )
        nodes.removeAll { node in
            if let normalizedSession, node.sessionId?.lowercased() != normalizedSession { return true }
            if let normalizedState, node.effectiveState.rawValue != normalizedState { return true }
            if let normalizedActivity, node.activity.state.rawValue != normalizedActivity { return true }
            if let normalizedWorkKind,
               !node.workloads.contains(where: {
                   $0.kind.rawValue == normalizedWorkKind && $0.phase.isActive
               }) { return true }
            return false
        }

        let edgeResolver = AgentSessionGraphEdgeResolver(nodes: nodes)
        let visibleNodeIDs = Set(nodes.map(\.nodeId))
        edges.removeAll {
            !visibleNodeIDs.contains($0.toNodeId) || edgeResolver.parentNodeId(for: $0) == nil
        }
        AgentSubtreeActivityProjector().project(nodes: &nodes, edges: edges)

        nodes.sort { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.runId < rhs.runId
        }
        edges.sort { lhs, rhs in
            if lhs.toNodeId != rhs.toNodeId { return lhs.toNodeId < rhs.toNodeId }
            return lhs.relationship.rawValue < rhs.relationship.rawValue
        }
        let snapshot = AgentSessionGraphSnapshot(nodes: nodes, edges: edges)
        if localJSONOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
        } else if snapshot.nodes.isEmpty {
            print(String(localized: "cli.agents.tree.output.noMatches", defaultValue: "No saved agent runs matched."))
        } else {
            for line in AgentTreeTextLineSequence(snapshot: snapshot, maximumDepth: maximumDepth) {
                print(line)
            }
        }
    }

    private func agentsTreeRuns(
        record: ClaudeHookSessionRecord,
        provider: String
    ) -> [AgentSessionRunRecord] {
        if let runs = record.runs, !runs.isEmpty { return runs }
        return [AgentSessionRunRecord(
            runId: record.runId ?? "session:\(provider):\(record.sessionId)",
            pid: record.pid,
            processStartedAt: nil,
            cmuxRuntime: record.cmuxRuntime,
            parentRunId: record.parentRunId,
            parentSessionId: record.parentSessionId,
            relationship: record.relationship,
            restoreAuthority: record.restoreAuthority ?? (record.relationship != .spawned),
            startedAt: record.startedAt,
            updatedAt: record.updatedAt
        )]
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
