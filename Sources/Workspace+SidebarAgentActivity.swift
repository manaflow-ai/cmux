import CmuxWorkspaces
import Foundation

@MainActor
extension Workspace {
    /// Builds the sidebar aggregate from cmux-owned runtime maps and the
    /// restart-safe cached hook index. No title/file-mtime fallback is used.
    func sidebarWorkspaceAgentActivity() -> SidebarWorkspaceAgentActivity {
        // Snapshot/body code must not schedule work. The shared index loader
        // publishes a notification when this cached value changes, and the
        // sidebar refresh handler rebuilds affected workspace snapshots.
        let liveIndex = SharedLiveAgentIndex.shared.index
        var evidenceByID: [String: SidebarAgentActivityEvidence] = [:]
        let panelIDs = Set(panels.keys)
            .union(agentLifecycleStatesByPanelId.keys)
            .union(agentPIDKeysByPanelId.keys)

        func addEvidence(_ evidence: SidebarAgentActivityEvidence) {
            if let existing = evidenceByID[evidence.id] {
                evidenceByID[evidence.id] = existing.merged(with: evidence)
            } else {
                evidenceByID[evidence.id] = evidence
            }
        }

        for panelID in panelIDs {
            let runtimeStates = agentLifecycleStatesByPanelId[panelID] ?? [:]
            let runtimeKeys = agentPIDKeysByPanelId[panelID] ?? []
            let indexEntry = liveIndex?.entry(workspaceId: id, panelId: panelID)
            let runtimeStatusKeys = Set(runtimeStates.keys.compactMap { key -> String? in
                guard !AgentHibernationLifecycleStatusKeys.isManualKey(key) else { return nil }
                return agentStatusKey(forAgentPIDKey: key)
            }).union(runtimeKeys.compactMap { key -> String? in
                let statusKey = agentStatusKey(forAgentPIDKey: key)
                guard AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(statusKey)
                        || runtimeStates[statusKey] != nil else {
                    return nil
                }
                return statusKey
            })

            var runtimeEvidence: [SidebarAgentActivityEvidence] = []
            for statusKey in runtimeStatusKeys.sorted() {
                let canonicalStatusKey = SidebarWorkspaceAgentActivity.canonicalStatusKey(statusKey)
                let lifecycle = Self.sidebarLifecycleState(
                    canonicalStatusKey: canonicalStatusKey,
                    states: runtimeStates,
                    statusKeyResolver: { agentStatusKey(forAgentPIDKey: $0) }
                )
                let matchingPIDKeys = runtimeKeys.filter {
                    SidebarWorkspaceAgentActivity.canonicalStatusKey(
                        agentStatusKey(forAgentPIDKey: $0)
                    ) == canonicalStatusKey
                }
                let selectedPIDKey = matchingPIDKeys.sorted { lhs, rhs in
                    let lhsIdentity = agentPIDProcessIdentitiesByKey[lhs]
                    let rhsIdentity = agentPIDProcessIdentitiesByKey[rhs]
                    let lhsIsLive = Self.processIdentityIsLive(lhsIdentity)
                    let rhsIsLive = Self.processIdentityIsLive(rhsIdentity)
                    if lhsIsLive != rhsIsLive { return lhsIsLive }
                    if lhsIdentity?.startSeconds != rhsIdentity?.startSeconds {
                        return (lhsIdentity?.startSeconds ?? Int64.max)
                            < (rhsIdentity?.startSeconds ?? Int64.max)
                    }
                    if lhsIdentity?.startMicroseconds != rhsIdentity?.startMicroseconds {
                        return (lhsIdentity?.startMicroseconds ?? Int64.max)
                            < (rhsIdentity?.startMicroseconds ?? Int64.max)
                    }
                    return lhs < rhs
                }.first
                let identity = selectedPIDKey.flatMap { agentPIDProcessIdentitiesByKey[$0] }
                let exactProcessIsLive = Self.processIdentityIsLive(identity)
                let runtimeSessionID = selectedPIDKey.flatMap {
                    Self.sessionID(agentPIDKey: $0, statusKey: statusKey)
                }
                let generation: SidebarAgentActivityEvidence.Generation
                if let runtimeSessionID {
                    generation = .session(runtimeSessionID)
                } else if let indexEntry,
                          SidebarWorkspaceAgentActivity.canonicalStatusKey(
                              indexEntry.snapshot.kind.rawValue
                          ) == canonicalStatusKey,
                          let identity,
                          Self.indexEntry(indexEntry, containsProcessIdentity: identity) {
                    // Claude's legacy runtime key has no session suffix. It may
                    // borrow the hook token only when both observations name
                    // the same exact process generation.
                    generation = .session(indexEntry.snapshot.sessionId)
                } else if let identity {
                    generation = .process(identity)
                } else {
                    generation = .lifecycle
                }
                let evidence = SidebarAgentActivityEvidence(
                    panelID: panelID,
                    statusKey: statusKey,
                    generation: generation,
                    lifecycle: lifecycle,
                    startedAt: Self.processStartTime(identity),
                    updatedAt: nil,
                    processLiveness: identity == nil
                        ? .unknown
                        : (exactProcessIsLive ? .running : .exited),
                    hasExactProcessIdentity: exactProcessIsLive,
                    isRuntimeBound: !matchingPIDKeys.isEmpty,
                    hasLiveLifecycleSignal: lifecycle != nil,
                    isHookBacked: false,
                    isExactProcessBinding: !matchingPIDKeys.isEmpty,
                    isHeuristicProcessDetection: false
                )
                runtimeEvidence.append(evidence)
                addEvidence(evidence)
            }

            guard let indexEntry else { continue }
            let statusKey = indexEntry.snapshot.kind.rawValue
            let canonicalStatusKey = SidebarWorkspaceAgentActivity.canonicalStatusKey(statusKey)
            let indexGeneration = SidebarAgentActivityEvidence.Generation.session(
                indexEntry.snapshot.sessionId
            )
            let indexIdentityProbe = SidebarAgentActivityEvidence(
                panelID: panelID,
                statusKey: statusKey,
                generation: indexGeneration,
                lifecycle: nil,
                startedAt: nil,
                updatedAt: nil,
                processLiveness: .unknown,
                hasExactProcessIdentity: false,
                isRuntimeBound: false,
                hasLiveLifecycleSignal: false,
                isHookBacked: indexEntry.hasHookRecord,
                isExactProcessBinding: indexEntry.hasExactProcessBinding,
                isHeuristicProcessDetection: indexEntry.isHeuristicProcessDetection
            )
            let currentRuntimeForKind = runtimeEvidence.filter {
                SidebarWorkspaceAgentActivity.canonicalStatusKey($0.statusKey)
                    == canonicalStatusKey
            }
            let runtimeMatchesIndexGeneration = currentRuntimeForKind.contains {
                $0.id == indexIdentityProbe.id
            }
            // A current runtime bound to a different session/process generation
            // supersedes this cached record. Never let the old SessionStart
            // anchor leak into the replacement agent.
            if !currentRuntimeForKind.isEmpty && !runtimeMatchesIndexGeneration {
                continue
            }

            let lifecycle = indexEntry.lifecycle
            let isRelevant = indexEntry.processLiveness == .running
                || (indexEntry.hasHookRecord && lifecycle != nil && lifecycle != .idle)
                || lifecycle == .running
                || lifecycle == .needsInput
            guard isRelevant else { continue }

            let heuristicOnly = indexEntry.isHeuristicProcessDetection
            let evidence = SidebarAgentActivityEvidence(
                panelID: panelID,
                statusKey: statusKey,
                generation: indexGeneration,
                lifecycle: lifecycle,
                startedAt: indexEntry.startedAt
                    ?? (indexEntry.hasExactProcessBinding
                        ? Self.processStartTime(indexEntry.agentProcessIdentities)
                        : nil),
                updatedAt: indexEntry.updatedAt,
                // A title/latest-file/fork-parent inference may aid restore,
                // but it cannot make lifecycle state confident in the sidebar.
                processLiveness: heuristicOnly ? .unknown : indexEntry.processLiveness,
                hasExactProcessIdentity: !heuristicOnly
                    && indexEntry.processLiveness == .running
                    && !indexEntry.agentProcessIdentities.isEmpty,
                isRuntimeBound: false,
                hasLiveLifecycleSignal: false,
                isHookBacked: indexEntry.hasHookRecord,
                isExactProcessBinding: indexEntry.hasExactProcessBinding,
                isHeuristicProcessDetection: heuristicOnly
            )
            addEvidence(evidence)
        }

        return SidebarWorkspaceAgentActivity.resolve(evidence: Array(evidenceByID.values))
    }

    private static func sidebarLifecycleState(
        canonicalStatusKey: String,
        states: [String: AgentHibernationLifecycleState],
        statusKeyResolver: (String) -> String
    ) -> AgentHibernationLifecycleState? {
        let matches = states.compactMap { key, state -> AgentHibernationLifecycleState? in
            let statusKey = SidebarWorkspaceAgentActivity.canonicalStatusKey(
                statusKeyResolver(key)
            )
            return statusKey == canonicalStatusKey ? state : nil
        }
        if matches.contains(.needsInput) { return .needsInput }
        if matches.contains(.running) { return .running }
        if matches.contains(.unknown) { return .unknown }
        if matches.contains(.idle) { return .idle }
        return nil
    }

    private static func sessionID(agentPIDKey: String, statusKey: String) -> String? {
        let prefix = statusKey + "."
        guard agentPIDKey.hasPrefix(prefix) else { return nil }
        let value = String(agentPIDKey.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func indexEntry(
        _ entry: RestorableAgentSessionIndex.Entry,
        containsProcessIdentity identity: AgentPIDProcessIdentity
    ) -> Bool {
        let identities = entry.agentProcessIdentities.isEmpty
            ? entry.processIdentities
            : entry.agentProcessIdentities
        return identities[Int(identity.pid)] == identity
    }

    private static func processIdentityIsLive(_ identity: AgentPIDProcessIdentity?) -> Bool {
        guard let identity,
              let currentIdentity = AgentPIDProcessIdentity(pid: identity.pid) else {
            return false
        }
        return currentIdentity == identity
    }

    private static func processStartTime(
        _ identities: [Int: AgentPIDProcessIdentity]
    ) -> TimeInterval? {
        processStartTime(identities.values.min { lhs, rhs in
            if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds < rhs.startSeconds }
            return lhs.startMicroseconds < rhs.startMicroseconds
        })
    }

    private static func processStartTime(_ identity: AgentPIDProcessIdentity?) -> TimeInterval? {
        guard let identity,
              identity.startSeconds >= 0,
              identity.startMicroseconds >= 0,
              identity.startMicroseconds < 1_000_000 else {
            return nil
        }
        return TimeInterval(identity.startSeconds)
            + TimeInterval(identity.startMicroseconds) / 1_000_000
    }
}
