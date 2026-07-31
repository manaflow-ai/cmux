import Foundation

/// Joins durable events to live and closed workspace topology in linear time.
struct VaultHistoryWorkspaceTimelineProjection: Sendable {
    struct Agent: Equatable, Sendable {
        let id: String
        let agent: SessionAgent
        let sessionId: String
        let title: String
        let updatedAt: Date
        let state: VaultHistoryWorkspaceTopology.AgentState
        let event: VaultHistoryEvent?
    }

    struct Terminal: Equatable, Sendable {
        let id: String
        let runtimeId: UUID?
        let title: String
        let directory: String?
        let agents: [Agent]
    }

    struct Section: Identifiable, Equatable, Sendable {
        let id: String
        let workspaceId: UUID?
        let title: String
        let directory: String?
        let windowLabel: String?
        let timestamp: Date
        let state: VaultHistoryWorkspaceTopology.WorkspaceState
        let isSelected: Bool
        let closedItemId: UUID?
        let terminals: [Terminal]
        let activityEvents: [VaultHistoryEvent]
    }

    func sections(
        topology: VaultHistoryWorkspaceTopology,
        events: [VaultHistoryEvent],
        query: VaultHistoryQuery,
        now: Date
    ) -> [Section] {
        let visibleEvents = query.visibleEvents(from: events, now: now)
        var workspaceIndexByIdentity: [String: Int] = [:]
        for (index, workspace) in topology.workspaces.enumerated() {
            for identity in Self.workspaceIdentities(workspace) {
                if workspaceIndexByIdentity[identity] == nil {
                    workspaceIndexByIdentity[identity] = index
                }
            }
        }

        var matchedEvents = Array(repeating: [VaultHistoryEvent](), count: topology.workspaces.count)
        var orphanEventsByIdentity: [String: [VaultHistoryEvent]] = [:]
        var orphanOrder: [String] = []
        for event in visibleEvents {
            let identities = Self.workspaceIdentities(event)
            if let index = identities.lazy.compactMap({ workspaceIndexByIdentity[$0] }).first {
                matchedEvents[index].append(event)
            } else if let identity = identities.first {
                if orphanEventsByIdentity[identity] == nil {
                    orphanOrder.append(identity)
                }
                orphanEventsByIdentity[identity, default: []].append(event)
            }
        }

        let searchTokens = query.searchText
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        var projected: [Section] = []
        for (index, workspace) in topology.workspaces.enumerated() {
            let eventsForWorkspace = matchedEvents[index]
            let searchMatches = searchTokens.isEmpty
                || !eventsForWorkspace.isEmpty
                || Self.topologyMatches(workspace, tokens: searchTokens)
            guard searchMatches else { continue }
            if workspace.state == .closed,
               !query.timeRange.includes(workspace.timestamp, relativeTo: now),
               eventsForWorkspace.isEmpty {
                continue
            }
            projected.append(section(
                workspace: workspace,
                events: eventsForWorkspace,
                sortOrder: query.sortOrder
            ))
        }

        for identity in orphanOrder {
            guard let orphanEvents = orphanEventsByIdentity[identity], !orphanEvents.isEmpty else {
                continue
            }
            projected.append(orphanSection(
                identity: identity,
                events: orphanEvents,
                sortOrder: query.sortOrder
            ))
        }
        return sortSections(projected, order: query.sortOrder)
    }

    private func section(
        workspace: VaultHistoryWorkspaceTopology.Workspace,
        events: [VaultHistoryEvent],
        sortOrder: VaultHistoryQuery.SortOrder
    ) -> Section {
        let terminalNodes = terminals(
            snapshots: workspace.terminals,
            sessionEvents: events.filter { $0.kind == .sessionActivity },
            sortOrder: sortOrder
        )
        let activityEvents = events.filter { $0.kind != .sessionActivity }
        let newestTimestamp = (
            terminalNodes.flatMap(\.agents).map(\.updatedAt)
                + events.map(\.timestamp)
                + [workspace.timestamp]
        ).max() ?? workspace.timestamp
        let latestTitle = activityEvents
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .max { $0.timestamp < $1.timestamp }?
            .title
        return Section(
            id: workspace.id,
            workspaceId: workspace.workspaceId,
            title: Self.normalized(workspace.title)
                ?? Self.normalized(latestTitle)
                ?? "",
            directory: workspace.directory,
            windowLabel: workspace.windowLabel,
            timestamp: newestTimestamp,
            state: workspace.state,
            isSelected: workspace.isSelected,
            closedItemId: workspace.closedItemId ?? Self.latestClosedItemId(in: activityEvents),
            terminals: terminalNodes,
            activityEvents: activityEvents
        )
    }

    private func orphanSection(
        identity: String,
        events: [VaultHistoryEvent],
        sortOrder: VaultHistoryQuery.SortOrder
    ) -> Section {
        let title = events
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .max { $0.timestamp < $1.timestamp }?
            .title ?? ""
        return Section(
            id: identity,
            workspaceId: nil,
            title: title,
            directory: events.lazy.compactMap(\.subject.directory).first,
            windowLabel: nil,
            timestamp: events.map(\.timestamp).max() ?? .distantPast,
            state: .closed,
            isSelected: false,
            closedItemId: Self.latestClosedItemId(in: events),
            terminals: terminals(
                snapshots: [],
                sessionEvents: events.filter { $0.kind == .sessionActivity },
                sortOrder: sortOrder
            ),
            activityEvents: events.filter { $0.kind != .sessionActivity }
        )
    }

    private func terminals(
        snapshots: [VaultHistoryWorkspaceTopology.Terminal],
        sessionEvents: [VaultHistoryEvent],
        sortOrder: VaultHistoryQuery.SortOrder
    ) -> [Terminal] {
        var nodes = snapshots.map { snapshot in
            TerminalBuilder(
                id: Self.terminalIdentity(id: snapshot.id, stableId: snapshot.stableId),
                runtimeId: snapshot.id,
                title: snapshot.title,
                directory: snapshot.directory,
                snapshots: snapshot.agentSessions,
                events: []
            )
        }
        var indexByIdentity: [String: Int] = [:]
        for (index, snapshot) in snapshots.enumerated() {
            indexByIdentity["surface:\(snapshot.id.uuidString)"] = index
            if let stableId = snapshot.stableId {
                indexByIdentity["surface-stable:\(stableId.uuidString)"] = index
            }
        }
        var syntheticIndexByIdentity: [String: Int] = [:]
        for event in sessionEvents {
            let identities = Self.surfaceIdentities(event)
            if let index = identities.lazy.compactMap({ indexByIdentity[$0] }).first {
                nodes[index].events.append(event)
                continue
            }
            let identity = identities.first ?? "session-terminal:\(event.id)"
            if let index = syntheticIndexByIdentity[identity] {
                nodes[index].events.append(event)
                continue
            }
            syntheticIndexByIdentity[identity] = nodes.count
            nodes.append(TerminalBuilder(
                id: identity,
                runtimeId: nil,
                title: "",
                directory: event.subject.directory,
                snapshots: [],
                events: [event]
            ))
        }
        return nodes.map { builder in
            Terminal(
                id: builder.id,
                runtimeId: builder.runtimeId,
                title: builder.title,
                directory: builder.directory,
                agents: agents(
                    snapshots: builder.snapshots,
                    events: builder.events,
                    sortOrder: sortOrder
                )
            )
        }
    }

    private func agents(
        snapshots: [VaultHistoryWorkspaceTopology.AgentSession],
        events: [VaultHistoryEvent],
        sortOrder: VaultHistoryQuery.SortOrder
    ) -> [Agent] {
        var builders: [String: AgentBuilder] = [:]
        var order: [String] = []
        for snapshot in snapshots {
            let key = Self.agentIdentity(
                agentId: snapshot.agent.rawValue,
                sessionId: snapshot.sessionId
            )
            order.append(key)
            builders[key] = AgentBuilder(
                agent: snapshot.agent,
                sessionId: snapshot.sessionId,
                title: snapshot.title ?? "",
                updatedAt: snapshot.updatedAt,
                state: snapshot.state,
                event: nil
            )
        }
        for event in events {
            guard let agentId = event.subject.agent,
                  let sessionId = event.subject.sessionId else {
                continue
            }
            let key = Self.agentIdentity(agentId: agentId, sessionId: sessionId)
            let resolvedAgent = SessionAgent(rawValue: agentId)
                ?? .registered(RegisteredSessionAgent(
                    id: agentId,
                    name: event.subject.agentDisplayName
                ))
            if var existing = builders[key] {
                existing.title = Self.normalized(event.title) ?? existing.title
                existing.updatedAt = max(existing.updatedAt, event.timestamp)
                existing.event = event
                builders[key] = existing
            } else {
                order.append(key)
                builders[key] = AgentBuilder(
                    agent: resolvedAgent,
                    sessionId: sessionId,
                    title: event.title,
                    updatedAt: event.timestamp,
                    state: .saved,
                    event: event
                )
            }
        }
        let result = order.compactMap { key -> Agent? in
            guard let builder = builders[key] else { return nil }
            return Agent(
                id: key,
                agent: builder.agent,
                sessionId: builder.sessionId,
                title: builder.title,
                updatedAt: builder.updatedAt,
                state: builder.state,
                event: builder.event
            )
        }
        return result.sorted { lhs, rhs in
            let lhsPriority = Self.agentStatePriority(lhs.state)
            let rhsPriority = Self.agentStatePriority(rhs.state)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            switch sortOrder {
            case .oldestFirst:
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            case .newestFirst, .titleAscending:
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            }
            return lhs.id < rhs.id
        }
    }

    private func sortSections(
        _ sections: [Section],
        order: VaultHistoryQuery.SortOrder
    ) -> [Section] {
        sections.sorted { lhs, rhs in
            if lhs.state != rhs.state { return lhs.state == .active }
            if lhs.isSelected != rhs.isSelected { return lhs.isSelected }
            switch order {
            case .newestFirst:
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            case .oldestFirst:
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            case .titleAscending:
                let comparison = lhs.title.localizedStandardCompare(rhs.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            return lhs.id < rhs.id
        }
    }

    private static func topologyMatches(
        _ workspace: VaultHistoryWorkspaceTopology.Workspace,
        tokens: [String]
    ) -> Bool {
        var fields = [
            workspace.title,
            workspace.directory ?? "",
            workspace.windowLabel ?? "",
            workspace.workspaceId?.uuidString ?? "",
            workspace.stableId?.uuidString ?? "",
        ]
        for terminal in workspace.terminals {
            fields.append(terminal.title)
            fields.append(terminal.directory ?? "")
            fields.append(terminal.id.uuidString)
            fields.append(terminal.stableId?.uuidString ?? "")
            for agent in terminal.agentSessions {
                fields.append(agent.title ?? "")
                fields.append(agent.agent.rawValue)
                fields.append(agent.agent.displayName)
                fields.append(agent.sessionId)
            }
        }
        return tokens.allSatisfy { token in
            fields.contains { $0.localizedCaseInsensitiveContains(token) }
        }
    }

    private static func workspaceIdentities(
        _ workspace: VaultHistoryWorkspaceTopology.Workspace
    ) -> [String] {
        [
            workspace.stableId.map { "workspace-stable:\($0.uuidString)" },
            workspace.workspaceId.map { "workspace:\($0.uuidString)" },
        ].compactMap { $0 }
    }

    private static func workspaceIdentities(_ event: VaultHistoryEvent) -> [String] {
        [
            event.subject.workspaceStableId.map { "workspace-stable:\($0.uuidString)" },
            event.subject.workspaceId.map { "workspace:\($0.uuidString)" },
        ].compactMap { $0 }
    }

    private static func surfaceIdentities(_ event: VaultHistoryEvent) -> [String] {
        [
            event.subject.surfaceStableId.map { "surface-stable:\($0.uuidString)" },
            event.subject.surfaceId.map { "surface:\($0.uuidString)" },
        ].compactMap { $0 }
    }

    private static func terminalIdentity(id: UUID, stableId: UUID?) -> String {
        stableId.map { "surface-stable:\($0.uuidString)" } ?? "surface:\(id.uuidString)"
    }

    private static func agentIdentity(agentId: String, sessionId: String) -> String {
        "agent-session:\(agentId):\(sessionId)"
    }

    private static func latestClosedItemId(in events: [VaultHistoryEvent]) -> UUID? {
        events
            .filter { $0.kind == .workspaceClosed && $0.subject.closedItemId != nil }
            .max { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                return lhs.id < rhs.id
            }?
            .subject
            .closedItemId
    }

    private static func agentStatePriority(
        _ state: VaultHistoryWorkspaceTopology.AgentState
    ) -> Int {
        switch state {
        case .running: return 0
        case .restoring: return 1
        case .hibernated: return 2
        case .saved: return 3
        }
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed == "." ? nil : trimmed
    }

    private struct TerminalBuilder {
        let id: String
        let runtimeId: UUID?
        let title: String
        let directory: String?
        let snapshots: [VaultHistoryWorkspaceTopology.AgentSession]
        var events: [VaultHistoryEvent]
    }

    private struct AgentBuilder {
        let agent: SessionAgent
        let sessionId: String
        var title: String
        var updatedAt: Date
        let state: VaultHistoryWorkspaceTopology.AgentState
        var event: VaultHistoryEvent?
    }
}
