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
        let (agentFilter, remainder0) = parseOption(commandArgs, name: "--agent")
        let (sessionFilter, remainder1) = parseOption(remainder0, name: "--session")
        let (workspaceFilter, remainder2) = parseOption(remainder1, name: "--workspace")
        let (surfaceFilter, remainder3) = parseOption(remainder2, name: "--surface")
        let (stateDirOverride, remainder4) = parseOption(remainder3, name: "--state-dir")
        let (relationshipFilter, remainder5) = parseOption(remainder4, name: "--relation")
        let (stateFilter, remainder6) = parseOption(remainder5, name: "--state")
        let (activityFilter, remainder7) = parseOption(remainder6, name: "--activity")
        let (workKindFilter, remainder8) = parseOption(remainder7, name: "--work-kind")
        let (depthRaw, remainder9) = parseOption(remainder8, name: "--depth")

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

        let specifications = [(name: "claude", suffix: "claude")] + Self.agentDefs.map {
            (name: $0.name, suffix: $0.sessionStoreSuffix)
        }
        let providerID = normalizedAgent.flatMap {
            agentSessionProviderID(for: $0, terminalObservations: terminalObservations)
        }
        if let normalizedAgent {
            let hasMatchingObservation = terminalObservations.contains {
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

        let matchingObservations = terminalObservations.filter { observation in
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
        } else {
            print(agentsTreeText(snapshot: snapshot, maximumDepth: maximumDepth))
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

    private func agentsTreeText(snapshot: AgentSessionGraphSnapshot, maximumDepth: Int) -> String {
        guard !snapshot.nodes.isEmpty else {
            return String(localized: "cli.agents.tree.output.noMatches", defaultValue: "No saved agent runs matched.")
        }
        let nodeById = AgentSessionGraphNodeIndex.nodes(snapshot.nodes)
        let edgeResolver = AgentSessionGraphEdgeResolver(nodes: snapshot.nodes)
        let childrenByRunId = Dictionary(grouping: snapshot.edges.compactMap { edge -> (String, AgentSessionGraphEdge)? in
            guard let parent = edgeResolver.parentNodeId(for: edge) else { return nil }
            return (parent, edge)
        }, by: \.0).mapValues { $0.map(\.1) }
        let childRunIds = Set(snapshot.edges.compactMap { edge in
            edgeResolver.parentNodeId(for: edge).map { _ in edge.toNodeId }
        })
        let roots = snapshot.nodes.filter { !childRunIds.contains($0.nodeId) }
        var lines: [String] = []
        var visited: Set<String> = []

        struct RenderFrame {
            var node: AgentSessionGraphNode
            var prefix: String
            var connector: String
            var depth: Int
        }

        func append(_ node: AgentSessionGraphNode, prefix: String, connector: String, depth: Int) {
            var stack = [RenderFrame(node: node, prefix: prefix, connector: connector, depth: depth)]
            while let frame = stack.popLast() {
                let node = frame.node
                guard frame.depth <= maximumDepth, visited.insert(node.nodeId).inserted else { continue }
                let authority: String
                if node.identitySource == "terminal_process" {
                    authority = " process"
                } else {
                    authority = node.restoreAuthority ? " restore-owner" : " child"
                }
                let modes = node.activity.modes.map(\.rawValue).joined(separator: ",")
                let activity = modes.isEmpty ? "" : " [\(modes)]"
                let identity = node.sessionId ?? "pid \(node.pid.map(String.init) ?? "unknown")"
                let location = "workspace:\(node.workspaceId) surface:\(node.surfaceId)"
                let workingDirectory = node.cwd.map { " cwd:\($0)" } ?? ""
                lines.append("\(frame.prefix)\(frame.connector)\(node.provider) \(identity) \(node.effectiveState.rawValue.uppercased())\(activity)\(authority) \(location)\(workingDirectory)")
                let children = (childrenByRunId[node.nodeId] ?? []).compactMap { nodeById[$0.toNodeId] }
                let childPrefix = frame.prefix
                    + (frame.connector == "├── " ? "│   " : frame.connector == "└── " ? "    " : "")
                for index in children.indices.reversed() {
                    stack.append(RenderFrame(
                        node: children[index],
                        prefix: childPrefix,
                        connector: index == children.count - 1 ? "└── " : "├── ",
                        depth: frame.depth + 1
                    ))
                }
            }
        }
        for root in roots { append(root, prefix: "", connector: "", depth: 0) }
        for node in snapshot.nodes where !visited.contains(node.nodeId) {
            append(node, prefix: "", connector: "", depth: 0)
        }
        return lines.joined(separator: "\n")
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
