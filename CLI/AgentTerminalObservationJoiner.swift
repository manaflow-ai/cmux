import CmuxFoundation
import Foundation

/// Reconciles cached terminal observations with durable hook-session nodes.
///
/// Matching requires cmux runtime, surface, provider, PID, and kernel process
/// start time. Ambiguous observations remain independent process nodes instead
/// of being attached to the wrong logical session.
struct AgentTerminalObservationJoiner: Sendable {
    func merge(
        nodes: [AgentSessionGraphNode],
        observations: [CmuxAgentTerminalObservation],
        activeSessionBySurface: [String: String]
    ) -> [AgentSessionGraphNode] {
        var result = nodes
        merge(
            nodes: &result,
            observations: observations,
            activeSessionBySurface: activeSessionBySurface
        )
        return result
    }

    func merge(
        nodes: inout [AgentSessionGraphNode],
        observations: [CmuxAgentTerminalObservation],
        activeSessionBySurface: [String: String]
    ) {
        let candidateIndices = Dictionary(grouping: nodes.indices) { index in
            Self.processKey(node: nodes[index])
        }
        for observation in observations {
            let matchingIndices = (candidateIndices[Self.processKey(observation: observation)] ?? []).filter { index in
                matches(nodes[index], observation: observation)
            }
            let activeSessionID = activeSessionBySurface[Self.surfaceKey(
                provider: observation.sessionProviderID,
                runtimeID: observation.runtimeID,
                surfaceID: observation.surfaceID.uuidString
            )]
            let selectedIndex: Int? = if let activeSessionID {
                matchingIndices.first { nodes[$0].sessionId == activeSessionID }
                    ?? (matchingIndices.count == 1 ? matchingIndices[0] : nil)
            } else {
                matchingIndices.count == 1 ? matchingIndices[0] : nil
            }
            if let selectedIndex {
                nodes[selectedIndex] = applying(observation, to: nodes[selectedIndex])
            } else {
                nodes.append(processNode(observation))
            }
        }
    }

    static func surfaceKey(provider: String, runtimeID: String, surfaceID: String) -> String {
        "\(provider)\u{1F}\(runtimeID)\u{1F}\(surfaceID.lowercased())"
    }

    static func processKey(node: AgentSessionGraphNode) -> String {
        guard node.identitySource == "hook_session",
              let runtimeID = node.cmuxRuntime?.id,
              let pid = node.pid else { return "" }
        return "\(surfaceKey(provider: node.provider, runtimeID: runtimeID, surfaceID: node.surfaceId))\u{1F}\(pid)"
    }

    static func processKey(observation: CmuxAgentTerminalObservation) -> String {
        let surface = surfaceKey(
            provider: observation.sessionProviderID,
            runtimeID: observation.runtimeID,
            surfaceID: observation.surfaceID.uuidString
        )
        return "\(surface)\u{1F}\(observation.pid)"
    }

    func matches(
        _ node: AgentSessionGraphNode,
        observation: CmuxAgentTerminalObservation
    ) -> Bool {
        guard node.identitySource == "hook_session",
              node.provider == observation.sessionProviderID,
              node.cmuxRuntime?.id == observation.runtimeID,
              node.surfaceId.lowercased() == observation.surfaceID.uuidString.lowercased(),
              node.pid == Int(observation.pid),
              let processStartedAt = node.processStartedAt else { return false }
        return abs(processStartedAt - observation.processStartedAt) <= 0.001
    }

    private func applying(
        _ observation: CmuxAgentTerminalObservation,
        to node: AgentSessionGraphNode
    ) -> AgentSessionGraphNode {
        var result = node
        result.terminalObservation = observation
        if result.cwd == nil { result.cwd = observation.cwd }
        guard result.sessionState == .active,
              (!observation.lifecycleAuthoritative || result.effectiveState == .unknown) else {
            return result
        }
        result.terminalStateApplied = true
        apply(observation.state, to: &result, preserveBackgroundActivity: true)
        return result
    }

    private func processNode(_ observation: CmuxAgentTerminalObservation) -> AgentSessionGraphNode {
        var node = AgentSessionGraphNode(
            provider: observation.sessionProviderID,
            sessionId: nil,
            runId: "pid:\(observation.pid)@\(observation.processStartMicrosecondsSinceEpoch):surface:\(observation.surfaceGeneration)",
            identitySource: "terminal_process",
            pid: Int(observation.pid),
            processStartedAt: observation.processStartedAt,
            cmuxRuntime: AgentCmuxRuntimeIdentity(
                id: observation.runtimeID,
                socketPath: nil,
                bundleIdentifier: nil
            ),
            workspaceId: observation.workspaceID.uuidString,
            surfaceId: observation.surfaceID.uuidString,
            cwd: observation.cwd,
            processState: .alive,
            sessionState: .active,
            foregroundState: .unknown,
            attentionState: .none,
            activity: AgentActivitySnapshot(
                state: .unknown,
                busy: false,
                modes: [],
                counts: AgentActivitySnapshot.Counts()
            ),
            effectiveState: .unknown,
            workloads: [],
            restoreAuthority: false,
            startedAt: observation.processStartedAt,
            updatedAt: observation.publishedAt,
            endedAt: nil,
            terminalObservation: observation,
            terminalStateApplied: true
        )
        apply(observation.state, to: &node, preserveBackgroundActivity: false)
        return node
    }

    private func apply(
        _ state: CmuxAgentObservedState,
        to node: inout AgentSessionGraphNode,
        preserveBackgroundActivity: Bool
    ) {
        var counts = preserveBackgroundActivity
            ? node.activity.counts
            : AgentActivitySnapshot.Counts()
        counts.foreground = state == .working ? 1 : 0
        node.foregroundState = state == .working ? .working : .idle
        node.attentionState = state == .blocked ? .needsInput : .none
        var modes = node.activity.modes.filter { $0 != .foreground }
        if counts.foreground > 0 { modes.insert(.foreground, at: 0) }
        node.activity = AgentActivitySnapshot(
            state: counts.total > 0 ? .busy : .idle,
            busy: counts.total > 0,
            modes: modes,
            counts: counts
        )
        if state == .blocked {
            node.effectiveState = .needsInput
        } else if counts.foreground + counts.backgroundTerminal + counts.subagent + counts.tool + counts.other > 0 {
            node.effectiveState = .working
        } else if counts.monitor > 0 {
            node.effectiveState = .monitoring
        } else if counts.scheduled > 0 {
            node.effectiveState = .scheduled
        } else {
            node.effectiveState = .idle
        }
    }
}

private extension CmuxAgentTerminalObservation {
    var processStartedAt: TimeInterval {
        TimeInterval(processStartSeconds) + TimeInterval(processStartMicroseconds) / 1_000_000
    }

    var processStartMicrosecondsSinceEpoch: Int64 {
        processStartSeconds * 1_000_000 + processStartMicroseconds
    }
}
