import CmuxWorkspaces
import Foundation

@MainActor
extension Workspace {
    private static let feedAttentionLifecyclePrefix = "cmux.feed.attention:"

    /// Builds the sidebar aggregate from cmux-owned runtime maps and the
    /// restart-safe cached hook index. No title/file-mtime fallback is used.
    func sidebarWorkspaceAgentActivity() -> SidebarWorkspaceAgentActivity {
        // Snapshot/body code must not schedule work. The shared index loader
        // publishes a notification when this cached value changes, and the
        // sidebar refresh handler rebuilds affected workspace snapshots.
        let sharedIndex = SharedLiveAgentIndex.shared
        let liveIndex = sharedIndex.index
        let indexLivenessIsFresh = sharedIndex.sidebarLivenessIsFresh()
        var evidenceByID: [String: SidebarAgentActivityEvidence] = [:]
        let panelIDs = Set(panels.keys)
            .union(agentLifecycleStatesByPanelId.keys)
            .union(agentPIDKeysByPanelId.keys)
        var manualLoadingCount = 0

        func addEvidence(_ evidence: SidebarAgentActivityEvidence) {
            if let existing = evidenceByID[evidence.id] {
                evidenceByID[evidence.id] = existing.merged(with: evidence)
            } else {
                evidenceByID[evidence.id] = evidence
            }
        }

        for panelID in panelIDs {
            let runtimeStates = agentLifecycleStatesByPanelId[panelID] ?? [:]
            manualLoadingCount += runtimeStates.reduce(into: 0) { count, pair in
                if AgentHibernationLifecycleStatusKeys.isManualKey(pair.key), pair.value == .running {
                    count += 1
                }
            }
            let runtimeKeys = agentPIDKeysByPanelId[panelID] ?? []
            let indexEntry = liveIndex?.sidebarEntry(workspaceId: id, panelId: panelID)
            var lifecycleByStatus: [String: AgentHibernationLifecycleState] = [:]
            for (key, state) in runtimeStates {
                guard !AgentHibernationLifecycleStatusKeys.isManualKey(key),
                      !key.hasPrefix(Self.feedAttentionLifecyclePrefix) else {
                    continue
                }
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
                // The runtime map retains the launch-time generation, but that
                // cache can outlive an exited process until its cleanup sweep.
                // Only a matching, revalidated shared-index entry may promote
                // it to live; otherwise fail closed and let a live lifecycle
                // event (if present) carry the status without PID confidence.
                let runtimeIndexEntry = indexLivenessIsFresh ? indexEntry.flatMap { entry in
                    SidebarWorkspaceAgentActivity.canonicalStatusKey(
                        entry.snapshot.kind.rawValue
                    ) == canonicalStatusKey ? entry : nil
                } : nil
                let livenessByPIDKey = Dictionary(uniqueKeysWithValues: matchingPIDKeys.map {
                    let identity = agentPIDProcessIdentitiesByKey[$0]
                    let isLive: Bool
                    if let runtimeIndexEntry,
                       runtimeIndexEntry.processLiveness == .running,
                       let identity,
                       Self.indexEntry(runtimeIndexEntry, containsProcessIdentity: identity) {
                        isLive = true
                    } else {
                        isLive = false
                    }
                    return ($0, isLive)
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
                let hasDifferentRuntimeGeneration = matchingPIDKeys.contains { key in
                    guard let runtimeIndexEntry,
                          let runtimeIdentity = agentPIDProcessIdentitiesByKey[key] else {
                        return false
                    }
                    return !Self.indexEntry(
                        runtimeIndexEntry,
                        containsProcessIdentity: runtimeIdentity
                    )
                }
                let suppressStaleLifecycle = runtimeIndexEntry?.processLiveness == .exited
                    && !hasDifferentRuntimeGeneration
                // A definitively exited indexed generation suppresses a stale
                // lifecycle map until a different cmux-bound generation is
                // recorded. Unknown index state remains eligible for a live
                // token-routed lifecycle signal.
                let processLiveness: RestorableAgentProcessLiveness = if exactProcessIsLive {
                    .running
                } else if suppressStaleLifecycle {
                    .exited
                } else {
                    .unknown
                }
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
                          indexEntry.processLiveness != .exited,
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
                    startedAt: nil,
                    updatedAt: nil,
                    processLiveness: processLiveness,
                    hasExactProcessIdentity: exactProcessIsLive,
                    isRuntimeBound: !matchingPIDKeys.isEmpty,
                    hasLiveLifecycleSignal: lifecycle != nil
                        && (matchingPIDKeys.isEmpty || indexLivenessIsFresh)
                        && !suppressStaleLifecycle,
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
            let currentRuntimeForDifferentKind = runtimeStatusKeys.contains { runtimeStatusKey in
                runtimeStatusKey != canonicalStatusKey
            }
            // A current runtime bound to a different session/process generation
            // supersedes this cached record. Never let the old SessionStart
            // anchor leak into the replacement agent.
            if currentRuntimeForDifferentKind
                || (!currentRuntimeForKind.isEmpty && !runtimeMatchesIndexGeneration) {
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
                startedAt: indexEntry.startedAt,
                updatedAt: indexEntry.updatedAt,
                // A title/latest-file/fork-parent inference may aid restore,
                // but it cannot make lifecycle state confident in the sidebar.
                processLiveness: heuristicOnly || !indexLivenessIsFresh
                    ? .unknown
                    : indexEntry.processLiveness,
                hasExactProcessIdentity: !heuristicOnly
                    && indexLivenessIsFresh
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

        return SidebarWorkspaceAgentActivity.resolve(
            evidence: Array(evidenceByID.values),
            manualLoadingCount: manualLoadingCount
        )
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

}
