import Foundation

extension CMUXCLI {
    func runAgentsTreeCommand(
        commandArgs: [String],
        jsonOutput: Bool,
        processEnv: [String: String],
        fileManager: FileManager
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
        let normalizedAgent = agentsTreeNormalized(agentFilter)?.lowercased()
        let normalizedSession = agentsTreeNormalized(sessionFilter)?.lowercased()
        let normalizedWorkspace = agentsTreeNormalizedID(workspaceFilter)?.lowercased()
        let normalizedSurface = agentsTreeNormalizedID(surfaceFilter)?.lowercased()
        let normalizedRelationship = agentsTreeNormalized(relationshipFilter)?.lowercased()
        let normalizedState = agentsTreeNormalized(stateFilter)?.lowercased()
        let normalizedActivity = agentsTreeNormalized(activityFilter)?.lowercased()
        let normalizedWorkKind = agentsTreeNormalized(workKindFilter)?.lowercased()
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
        var nodes: [AgentSessionGraphNode] = []
        var edges: [AgentSessionGraphEdge] = []
        let decoder = JSONDecoder()

        for specification in specifications {
            if let normalizedAgent, specification.name.lowercased() != normalizedAgent { continue }
            let url = URL(fileURLWithPath: stateDirectory, isDirectory: true)
                .appendingPathComponent("\(specification.suffix)-hook-sessions.json", isDirectory: false)
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let store = try? decoder.decode(ClaudeHookSessionStoreFile.self, from: data) else {
                continue
            }
            let activeSessionIds = Set(store.activeSessionsBySurface.values.map(\.sessionId))
                .union(store.activeSessionsByWorkspace.values.map(\.sessionId))
            for record in store.sessions.values {
                if let normalizedSession, record.sessionId.lowercased() != normalizedSession { continue }
                if let normalizedWorkspace, record.workspaceId.lowercased() != normalizedWorkspace { continue }
                if let normalizedSurface, record.surfaceId.lowercased() != normalizedSurface { continue }
                if !includeAll,
                   !activeSessionIds.contains(record.sessionId),
                   record.isRestorable != true,
                   record.transcriptPath == nil,
                   record.launchCommand == nil {
                    continue
                }

                let runs = agentsTreeRuns(record: record, provider: specification.name)
                for run in runs {
                    let projection = AgentSessionStateProjection(record: record, run: run)
                    if let normalizedState, projection.effective.rawValue != normalizedState { continue }
                    if let normalizedActivity, projection.activity.state.rawValue != normalizedActivity { continue }
                    if let normalizedWorkKind,
                       !(record.workloads ?? []).contains(where: {
                           $0.kind.rawValue == normalizedWorkKind && $0.phase.isActive
                       }) { continue }
                    let node = AgentSessionGraphNode(
                        provider: specification.name,
                        sessionId: record.sessionId,
                        runId: run.runId,
                        pid: run.pid,
                        processStartedAt: run.processStartedAt,
                        workspaceId: record.workspaceId,
                        surfaceId: record.surfaceId,
                        processState: projection.process,
                        sessionState: projection.session,
                        foregroundState: projection.foreground,
                        attentionState: projection.attention,
                        activity: projection.activity,
                        effectiveState: projection.effective,
                        workloads: (record.workloads ?? []).map(AgentWorkloadSnapshot.init),
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
                            toRunId: run.runId,
                            relationship: relationship
                        ))
                    }
                }
            }
        }

        AgentSubtreeActivityProjector().project(nodes: &nodes, edges: edges)

        nodes.sort { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.runId < rhs.runId
        }
        edges.sort { lhs, rhs in
            if lhs.toRunId != rhs.toRunId { return lhs.toRunId < rhs.toRunId }
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
        let nodeByRunId = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.runId, $0) })
        let childrenByRunId = Dictionary(grouping: snapshot.edges.compactMap { edge -> (String, AgentSessionGraphEdge)? in
            guard let parent = edge.fromRunId, nodeByRunId[parent] != nil else { return nil }
            return (parent, edge)
        }, by: \.0).mapValues { $0.map(\.1) }
        let childRunIds = Set(snapshot.edges.compactMap { edge in
            edge.fromRunId.flatMap { nodeByRunId[$0] == nil ? nil : edge.toRunId }
        })
        let roots = snapshot.nodes.filter { !childRunIds.contains($0.runId) }
        var lines: [String] = []
        var visited: Set<String> = []

        func append(_ node: AgentSessionGraphNode, prefix: String, depth: Int) {
            guard depth <= maximumDepth, visited.insert(node.runId).inserted else { return }
            let authority = node.restoreAuthority ? " restore-owner" : " child"
            let modes = node.activity.modes.map(\.rawValue).joined(separator: ",")
            let activity = modes.isEmpty ? "" : " [\(modes)]"
            lines.append("\(prefix)\(node.provider) \(node.sessionId) \(node.effectiveState.rawValue.uppercased())\(activity)\(authority) \(node.surfaceId)")
            let children = (childrenByRunId[node.runId] ?? []).compactMap { nodeByRunId[$0.toRunId] }
            for (index, child) in children.enumerated() {
                append(child, prefix: prefix + (index == children.count - 1 ? "└── " : "├── "), depth: depth + 1)
            }
        }
        for root in roots { append(root, prefix: "", depth: 0) }
        for node in snapshot.nodes where !visited.contains(node.runId) { append(node, prefix: "", depth: 0) }
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
