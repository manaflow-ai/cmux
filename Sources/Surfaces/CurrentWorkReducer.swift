import Foundation

/// Reduces an immutable owner capture. It performs no I/O and owns no mutable graph.
struct CurrentWorkReducer {
    func reduce(_ input: CurrentWorkInput, limit: Int = 100) -> CurrentWorkSnapshot {
        let observedAt = input.observedAt.ISO8601Format()
        let catalog = input.export.catalog
        let projections = Dictionary(grouping: catalog.projections, by: \.resource)
        let states = Dictionary(input.export.cloudStates.map { ($0.machine, $0) }, uniquingKeysWith: { first, _ in first })
        let selected = catalog.resources.sorted { $0.id.rawValue < $1.id.rawValue }.prefix(min(200, max(1, limit)))
        let items = selected.map { resource -> CurrentWorkSnapshot.Item in
            let local = resource.machine.isLocal
            let state = states[resource.machine]
            let observation = input.export.cloudStateObservations[resource.machine]
            let fresh = CurrentWorkSnapshot.Freshness(
                state: local ? "current" : observation?.freshness.rawValue ?? "unknown",
                reason: local ? nil : observation?.reason ?? (observation == nil ? "no_cloud_observation" : nil),
                observedAt: observedAt
            )
            let allProjections = (projections[resource.id] ?? []).sorted { $0.panelID.uuidString < $1.panelID.uuidString }
            let boundedProjections = Array(allProjections.prefix(16))
            let projected = boundedProjections.map { projection in
                let identity = input.export.projectionIdentities[projection]
                return CurrentWorkSnapshot.Projection(
                    resourceRef: resource.id.rawValue, workspaceID: projection.workspaceID, panelID: projection.panelID,
                    stableSurfaceID: identity?.stableSurfaceID, stableWorkspaceID: identity?.stableWorkspaceID,
                    remoteWorkspaceID: projection.remoteWorkspaceID, remoteTabID: projection.remoteTabID
                )
            }
            let stableIDs = Set(allProjections.compactMap { input.export.projectionIdentities[$0]?.stableSurfaceID })
            let workspaceIDs = Set(boundedProjections.map(\.workspaceID)).sorted { $0.uuidString < $1.uuidString }
            var projects: [String] = []
            var repositories: [String] = []
            var prs: [CurrentWorkSnapshot.PullRequest] = []
            var attention: [CurrentWorkSnapshot.Attention] = []
            var evidence = [CurrentWorkSnapshot.Evidence(owner: "SurfaceCatalog", reference: resource.id.rawValue, observedAt: observedAt)]
            for id in workspaceIDs {
                guard let facts = input.workspaces[id] else { continue }
                if let root = facts.projectRoot, !projects.contains(root) { projects.append(bounded(root)) }
                prs.append(contentsOf: facts.pullRequests)
                for pr in facts.pullRequests where !repositories.contains(pr.label) { repositories.append(pr.label) }
                evidence.append(.init(owner: "Workspace.sidebarMetadata", reference: id.uuidString, observedAt: observedAt))
                if facts.unreadCount > 0 {
                    attention.append(.init(kind: "unread", scope: "workspace", evidence: .init(
                        owner: "SidebarUnreadModel", reference: facts.notificationID?.uuidString ?? id.uuidString, observedAt: observedAt
                    )))
                }
            }
            var agents: [CurrentWorkSnapshot.Agent] = []
            var seenSessions: Set<String> = []
            for projection in boundedProjections {
                for agent in input.agentsByPanelID[projection.panelID] ?? [] {
                    let key = "\(agent.kind ?? "unknown")/\(agent.sessionID ?? "unknown")"
                    if seenSessions.insert(key).inserted { agents.append(agent) }
                }
                if input.unreadPanelIDs.contains(projection.panelID) {
                    attention.append(.init(kind: "unread", scope: "surface", evidence: .init(
                        owner: "SidebarUnreadModel", reference: projection.panelID.uuidString, observedAt: observedAt
                    )))
                }
            }
            if let badge = resource.agent, agents.isEmpty {
                agents.append(.init(sessionID: nil, kind: badge.source, state: bounded(badge.state), hasHookLifecycleState: false,
                                    version: nil, lastActivityAt: nil, evidence: .init(owner: "SurfaceCatalog", reference: resource.id.rawValue, observedAt: observedAt)))
            }
            let boundedAgents = Array(agents.prefix(8))
            let obligations = boundedAgents.compactMap { agent -> CurrentWorkSnapshot.Obligation? in
                guard fresh.state == "current", agent.hasHookLifecycleState, agent.state == "needs_input" else { return nil }
                return .init(kind: "needs_input",
                             freshness: .init(state: "unknown", reason: "hook_state_observed_without_liveness_timestamp", observedAt: observedAt),
                             evidence: agent.evidence)
            }
            for agent in boundedAgents where agent.state == "needs_input" {
                attention.append(.init(kind: "needs_input", scope: "agent", evidence: agent.evidence))
            }
            let pending = (observation?.pendingWrites ?? []).filter { $0.resource == resource.id }
            let receipts = pending.prefix(8).map { mutation in
                CurrentWorkSnapshot.Receipt(kind: mutation.kind.rawValue, cursor: mutation.receipt,
                                            evidence: .init(owner: "SurfaceCatalog", reference: resource.id.rawValue, observedAt: observedAt))
            }
            return CurrentWorkSnapshot.Item(
                resourceRef: resource.id.rawValue, durableSurfaceID: local && stableIDs.count == 1 ? stableIDs.first : nil,
                label: bounded(resource.title), kind: resource.kind.rawValue, lifecycle: resource.lifecycle.rawValue,
                placement: .init(kind: local ? "local" : "cloud", machine: resource.machine.rawValue), projections: projected,
                cwd: resource.kind == .terminal ? resource.detail.map { bounded($0) } : nil,
                projectHints: Array(projects.prefix(8)), repositoryHints: Array(repositories.prefix(8)), agents: boundedAgents, attention: Array(attention.prefix(24)),
                pullRequests: Array(prs.prefix(16)), freshness: fresh, cursor: state?.cursor, receiptRefs: receipts,
                possibleHumanObligations: obligations, evidence: evidence,
                omitted: ["projections": max(0, allProjections.count - 16), "agents": max(0, agents.count - 8),
                          "attention": max(0, attention.count - 24), "pull_requests": max(0, prs.count - 16),
                          "project_hints": max(0, projects.count - 8), "repository_hints": max(0, repositories.count - 8), "receipt_refs": max(0, pending.count - 8)]
            )
        }
        return CurrentWorkSnapshot(observedAt: observedAt, totalObserved: catalog.resources.count,
                                   truncated: items.count < catalog.resources.count,
                                   ownerAvailability: ["agent_sessions": input.agentOwnerAvailable ? "available" : "unavailable",
                                                       "cloud_state": "cached_only", "pull_requests": "workspace_summary_only"], items: items)
    }

    private func bounded(_ value: String) -> String { String(value.prefix(2048)) }
}
