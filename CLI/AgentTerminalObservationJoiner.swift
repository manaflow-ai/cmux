import CmuxFoundation
import Foundation

/// Retains same-process siblings for exact-session reconciliation without
/// admitting a different kernel process generation that reused the numeric PID.
/// Missing start metadata remains a wildcard for compatibility with legacy rows.
struct AgentSessionProcessCohortMatcher: Sendable {
    private struct Base: Hashable, Sendable {
        var provider: String
        var runtimeID: String
        var surfaceID: String
        var pid: Int
    }

    private var allBases: Set<Base> = []
    private var basesWithUnknownStart: Set<Base> = []
    private var startMillisecondsByBase: [Base: Set<Int64>] = [:]

    mutating func insert(
        provider: String,
        record: ClaudeHookSessionRecord,
        run: AgentSessionRunRecord
    ) {
        guard let base = base(provider: provider, record: record, run: run) else { return }
        allBases.insert(base)
        if let startedAt = run.processStartedAt {
            startMillisecondsByBase[base, default: []].insert(Self.milliseconds(startedAt))
        } else {
            basesWithUnknownStart.insert(base)
        }
    }

    func matches(
        provider: String,
        record: ClaudeHookSessionRecord,
        run: AgentSessionRunRecord
    ) -> Bool {
        guard let base = base(provider: provider, record: record, run: run),
              allBases.contains(base) else { return false }
        guard let startedAt = run.processStartedAt else { return true }
        if basesWithUnknownStart.contains(base) { return true }
        let milliseconds = Self.milliseconds(startedAt)
        let knownStarts = startMillisecondsByBase[base] ?? []
        return knownStarts.contains(milliseconds - 1)
            || knownStarts.contains(milliseconds)
            || knownStarts.contains(milliseconds + 1)
    }

    private func base(
        provider: String,
        record: ClaudeHookSessionRecord,
        run: AgentSessionRunRecord
    ) -> Base? {
        guard run.identityConflict != true,
              let runtimeID = run.cmuxRuntime(fallingBackTo: record.cmuxRuntime)?.id,
              let pid = run.pid else { return nil }
        return Base(
            provider: provider,
            runtimeID: runtimeID,
            surfaceID: record.surfaceId.lowercased(),
            pid: pid
        )
    }

    private static func milliseconds(_ value: TimeInterval) -> Int64 {
        Int64((value * 1_000).rounded())
    }
}

/// Retains only the session candidates needed to decide whether a terminal
/// observation has one match, an active-slot match, or an ambiguous match.
/// The full lifecycle rows are emitted by the caller's normal store pass.
struct AgentTerminalObservationCandidateAccumulator {
    private struct Bucket {
        var observation: CmuxAgentTerminalObservation
        var activeSessionID: String?
        var activeCandidateNodeID: String?
        var fallbackCandidateNodeIDs: [String] = []
    }

    private var bucketsByIdentity: [String: Bucket] = [:]
    private var identitiesByProcessKey: [String: [String]] = [:]
    private var nodesByID: [String: AgentSessionGraphNode] = [:]
    private let joiner = AgentTerminalObservationJoiner()

    init(
        observations: [CmuxAgentTerminalObservation],
        activeSessionBySurface: [String: String]
    ) {
        let observations = AgentTerminalObservationJoiner.canonicalObservations(observations)
        bucketsByIdentity.reserveCapacity(observations.count)
        identitiesByProcessKey.reserveCapacity(observations.count)
        nodesByID.reserveCapacity(min(observations.count, 341) * 3)
        for observation in observations {
            let identity = Self.observationIdentity(observation)
            let surfaceKey = AgentTerminalObservationJoiner.surfaceKey(
                provider: observation.sessionProviderID,
                runtimeID: observation.runtimeID,
                surfaceID: observation.surfaceID.uuidString
            )
            bucketsByIdentity[identity] = Bucket(
                observation: observation,
                activeSessionID: activeSessionBySurface[surfaceKey]
            )
            identitiesByProcessKey[
                AgentTerminalObservationJoiner.processKey(observation: observation),
                default: []
            ].append(identity)
        }
    }

    var retainedCount: Int { retainedCandidates.count }

    func contains(nodeID: String) -> Bool { nodesByID[nodeID] != nil }

    var retainedCandidates: [AgentSessionGraphNode] {
        var retainedNodeIDs: Set<String> = []
        retainedNodeIDs.reserveCapacity(nodesByID.count)
        for bucket in bucketsByIdentity.values {
            if let activeCandidateNodeID = bucket.activeCandidateNodeID {
                retainedNodeIDs.insert(activeCandidateNodeID)
            }
            retainedNodeIDs.formUnion(bucket.fallbackCandidateNodeIDs)
        }
        return retainedNodeIDs.compactMap { nodesByID[$0] }.sorted {
            $0.nodeId < $1.nodeId
        }
    }

    mutating func insert(_ node: AgentSessionGraphNode) {
        let processKey = AgentTerminalObservationJoiner.processKey(node: node)
        guard !processKey.isEmpty,
              let identities = identitiesByProcessKey[processKey] else {
            return
        }
        for identity in identities {
            guard var bucket = bucketsByIdentity[identity],
                  joiner.matches(node, observation: bucket.observation) else {
                continue
            }
            let nodeID = node.nodeId
            if let activeSessionID = bucket.activeSessionID,
               node.sessionId == activeSessionID {
                if bucket.activeCandidateNodeID == nodeID {
                    nodesByID[nodeID] = node
                } else if bucket.activeCandidateNodeID == nil {
                    bucket.activeCandidateNodeID = nodeID
                    nodesByID[nodeID] = node
                }
            } else if bucket.fallbackCandidateNodeIDs.contains(nodeID) {
                nodesByID[nodeID] = node
            } else if bucket.fallbackCandidateNodeIDs.count < 2 {
                bucket.fallbackCandidateNodeIDs.append(nodeID)
                nodesByID[nodeID] = node
            }
            bucketsByIdentity[identity] = bucket
        }
    }

    private static func observationIdentity(_ observation: CmuxAgentTerminalObservation) -> String {
        "\(AgentTerminalObservationJoiner.processKey(observation: observation))\u{1F}"
            + "\(observation.surfaceGeneration)\u{1F}"
            + "\(observation.processStartSeconds)\u{1F}"
            + "\(observation.processStartMicroseconds)"
    }
}

/// Reconciles cached terminal observations with durable hook-session nodes.
///
/// Matching requires cmux runtime, surface, provider, PID, and kernel process
/// start time. Ambiguous observations remain independent process nodes instead
/// of being attached to the wrong logical session.
struct AgentTerminalObservationJoiner: Sendable {
    /// Detector family, provider, state, and workspace are mutable metadata.
    /// The runtime-owned terminal generation plus kernel PID lifetime is the
    /// stable identity used to collapse repeated publications.
    private struct ProcessIdentity: Hashable, Sendable {
        let runtimeID: String
        let surfaceID: UUID
        let surfaceGeneration: UInt64
        let pid: Int32
        let processStartSeconds: Int64
        let processStartMicroseconds: Int64

        init(_ observation: CmuxAgentTerminalObservation) {
            runtimeID = observation.runtimeID
            surfaceID = observation.surfaceID
            surfaceGeneration = observation.surfaceGeneration
            pid = observation.pid
            processStartSeconds = observation.processStartSeconds
            processStartMicroseconds = observation.processStartMicroseconds
        }
    }

    static func canonicalObservations(
        _ observations: [CmuxAgentTerminalObservation]
    ) -> [CmuxAgentTerminalObservation] {
        var result: [CmuxAgentTerminalObservation] = []
        var indexByIdentity: [ProcessIdentity: Int] = [:]
        result.reserveCapacity(observations.count)
        indexByIdentity.reserveCapacity(observations.count)

        for observation in observations {
            let identity = ProcessIdentity(observation)
            if let index = indexByIdentity[identity] {
                if prefers(observation, over: result[index]) {
                    result[index] = observation
                }
            } else {
                indexByIdentity[identity] = result.count
                result.append(observation)
            }
        }
        return result
    }

    func merge(
        nodes: [AgentSessionGraphNode],
        observations: [CmuxAgentTerminalObservation],
        activeSessionBySurface: [String: String]
    ) -> [AgentSessionGraphNode] {
        var result = nodes
        _ = merge(
            nodes: &result,
            observations: observations,
            activeSessionBySurface: activeSessionBySurface
        )
        return result
    }

    @discardableResult
    func merge(
        nodes: inout [AgentSessionGraphNode],
        observations: [CmuxAgentTerminalObservation],
        activeSessionBySurface: [String: String],
        maximumNodeCount: Int? = nil,
        includeUnmatchedNode: (AgentSessionGraphNode) -> Bool = { _ in true }
    ) -> Bool {
        let candidateIndices = Dictionary(grouping: nodes.indices) { index in
            Self.processKey(node: nodes[index])
        }
        for observation in Self.canonicalObservations(observations) {
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
                let node = processNode(observation)
                guard includeUnmatchedNode(node) else { continue }
                if let maximumNodeCount, nodes.count >= maximumNodeCount { return false }
                nodes.append(node)
            }
        }
        return true
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

    private static func prefers(
        _ candidate: CmuxAgentTerminalObservation,
        over existing: CmuxAgentTerminalObservation
    ) -> Bool {
        if candidate.publishedAt != existing.publishedAt {
            return candidate.publishedAt > existing.publishedAt
        }
        if candidate.revision != existing.revision { return candidate.revision > existing.revision }
        if candidate.runtimeID != existing.runtimeID { return candidate.runtimeID > existing.runtimeID }
        let candidateWorkspaceID = candidate.workspaceID.uuidString.lowercased()
        let existingWorkspaceID = existing.workspaceID.uuidString.lowercased()
        if candidateWorkspaceID != existingWorkspaceID { return candidateWorkspaceID > existingWorkspaceID }
        let candidateSurfaceID = candidate.surfaceID.uuidString.lowercased()
        let existingSurfaceID = existing.surfaceID.uuidString.lowercased()
        if candidateSurfaceID != existingSurfaceID { return candidateSurfaceID > existingSurfaceID }
        if candidate.surfaceGeneration != existing.surfaceGeneration {
            return candidate.surfaceGeneration > existing.surfaceGeneration
        }
        if candidate.familyID != existing.familyID { return candidate.familyID > existing.familyID }
        if candidate.sessionProviderID != existing.sessionProviderID {
            return candidate.sessionProviderID > existing.sessionProviderID
        }
        if candidate.lifecycleAuthoritative != existing.lifecycleAuthoritative {
            return candidate.lifecycleAuthoritative
        }
        if candidate.state.rawValue != existing.state.rawValue {
            return candidate.state.rawValue > existing.state.rawValue
        }
        if candidate.pid != existing.pid { return candidate.pid > existing.pid }
        if candidate.processStartSeconds != existing.processStartSeconds {
            return candidate.processStartSeconds > existing.processStartSeconds
        }
        if candidate.processStartMicroseconds != existing.processStartMicroseconds {
            return candidate.processStartMicroseconds > existing.processStartMicroseconds
        }
        switch (candidate.cwd, existing.cwd) {
        case let (candidate?, existing?) where candidate != existing:
            return candidate > existing
        case (_?, nil):
            return true
        default:
            return false
        }
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
        result.workspaceId = observation.workspaceID.uuidString
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
