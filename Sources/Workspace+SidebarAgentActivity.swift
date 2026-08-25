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
            var lifecycleByStatus: [String: AgentHibernationLifecycleState] = [:]
            for (key, state) in runtimeStates {
                guard !AgentHibernationLifecycleStatusKeys.isManualKey(key) else { continue }
                let canonicalStatusKey = SidebarWorkspaceAgentActivity.canonicalStatusKey(
                    agentStatusKey(forAgentPIDKey: key)
                )
                if let existing = lifecycleByStatus[canonicalStatusKey],
                   Self.sidebarLifecyclePriority(existing) <= Self.sidebarLifecyclePriority(state) {
                    continue
                }
                lifecycleByStatus[canonicalStatusKey] = state
            }
            var runtimeKeysByStatus: [String: [String]] = [:]
            for key in runtimeKeys {
                let statusKey = agentStatusKey(forAgentPIDKey: key)
                guard AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(statusKey)
                        || runtimeStates[statusKey] != nil else {
                    continue
                }
                let canonicalStatusKey = SidebarWorkspaceAgentActivity.canonicalStatusKey(statusKey)
                runtimeKeysByStatus[canonicalStatusKey, default: []].append(key)
            }
            let runtimeStatusKeys = Set(lifecycleByStatus.keys).union(runtimeKeysByStatus.keys)

            var runtimeEvidence: [SidebarAgentActivityEvidence] = []
            for statusKey in runtimeStatusKeys.sorted() {
                let canonicalStatusKey = SidebarWorkspaceAgentActivity.canonicalStatusKey(statusKey)
                let lifecycle = lifecycleByStatus[canonicalStatusKey]
                let matchingPIDKeys = runtimeKeysByStatus[canonicalStatusKey] ?? []
                // The runtime map retains the exact process generation accepted
                // at the launch/hook binding. The centralized stale-PID sweep
                // removes that identity when the generation exits; reusing the
                // retained evidence here avoids a synchronous sysctl probe in
                // the main-actor snapshot path.
                let livenessByPIDKey = Dictionary(uniqueKeysWithValues: matchingPIDKeys.map {
                    ($0, agentPIDProcessIdentitiesByKey[$0] != nil)
                })
                let selectedPIDKey = matchingPIDKeys.min { lhs, rhs in
                    let lhsIdentity = agentPIDProcessIdentitiesByKey[lhs]
                    let rhsIdentity = agentPIDProcessIdentitiesByKey[rhs]
                    let lhsIsLive = livenessByPIDKey[lhs] ?? false
                    let rhsIsLive = livenessByPIDKey[rhs] ?? false
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
                }
                let identity = selectedPIDKey.flatMap { agentPIDProcessIdentitiesByKey[$0] }
                let exactProcessIsLive = selectedPIDKey.flatMap { livenessByPIDKey[$0] } ?? false
                let runtimeSessionID = selectedPIDKey.flatMap {
                    Self.sessionID(agentPIDKey: $0, statusKey: statusKey)
                }
                let generation: SidebarAgentActivityEvidence.Generation
                if let runtimeSessionID {
                    generation = .session(runtimeSessionID)
                } else if matchingPIDKeys.isEmpty,
                          let indexEntry,
                          SidebarWorkspaceAgentActivity.canonicalStatusKey(
                              indexEntry.snapshot.kind.rawValue
                          ) == canonicalStatusKey,
                          !indexEntry.snapshot.sessionId.isEmpty {
                    // A token-routed lifecycle event is bound to this panel but
                    // may not carry a session suffix (for example during the
                    // first hook transition). Correlate it with the panel's
                    // single cached session so it merges the durable anchor
                    // instead of creating a second lifecycle-only agent.
                    generation = .session(indexEntry.snapshot.sessionId)
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

    nonisolated private static func sidebarLifecyclePriority(
        _ state: AgentHibernationLifecycleState
    ) -> Int {
        switch state {
        case .needsInput: 0
        case .running: 1
        case .unknown: 2
        case .idle: 3
        }
    }

    nonisolated private static func sessionID(agentPIDKey: String, statusKey: String) -> String? {
        let prefix = statusKey + "."
        guard agentPIDKey.hasPrefix(prefix) else { return nil }
        let value = String(agentPIDKey.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    nonisolated private static func indexEntry(
        _ entry: RestorableAgentSessionIndex.Entry,
        containsProcessIdentity identity: AgentPIDProcessIdentity
    ) -> Bool {
        let identities = entry.agentProcessIdentities.isEmpty
            ? entry.processIdentities
            : entry.agentProcessIdentities
        return identities[Int(identity.pid)] == identity
    }

    nonisolated private static func processStartTime(
        _ identities: [Int: AgentPIDProcessIdentity]
    ) -> TimeInterval? {
        processStartTime(identities.values.min { lhs, rhs in
            if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds < rhs.startSeconds }
            return lhs.startMicroseconds < rhs.startMicroseconds
        })
    }

    nonisolated private static func processStartTime(_ identity: AgentPIDProcessIdentity?) -> TimeInterval? {
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
