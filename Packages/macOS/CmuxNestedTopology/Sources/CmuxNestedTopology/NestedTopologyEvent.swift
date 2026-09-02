/// Incremental or replacement topology mutation from a nested provider.
///
/// Public encoding is versioned through the associated snapshot/node Codable forms.
public enum NestedTopologyEvent: Hashable, Codable, Sendable {
    /// Replace the entire topology with a validated snapshot.
    case replaceSnapshot(NestedTopologySnapshot)
    /// Insert or update a workspace.
    case workspaceUpserted(NestedWorkspaceNode)
    /// Close a workspace and cascade-close descendants.
    case workspaceClosed(NestedNodeID)
    /// Insert or update a tab.
    case tabUpserted(NestedTabNode)
    /// Close a tab and cascade-close descendants.
    case tabClosed(NestedNodeID)
    /// Insert or update a pane.
    case paneUpserted(NestedPaneNode)
    /// Close a pane and cascade-close descendants.
    case paneClosed(NestedNodeID)
    /// Insert or update an agent.
    case agentUpserted(NestedAgentNode)
    /// Close an agent.
    case agentClosed(NestedNodeID)
    /// Replace focus records.
    case focusChanged(NestedFocus)
    /// Update only a node's display title.
    case titleUpdated(id: NestedNodeID, displayTitle: String)
    /// Update only an agent's status fields.
    case agentStatusUpdated(id: NestedNodeID, status: NestedAgentStatus, providerRawStatus: String)

    enum CodingKeys: String, CodingKey {
        case type
        case snapshot
        case workspace
        case tab
        case pane
        case agent
        case id
        case focus
        case displayTitle = "display_title"
        case status
        case providerRawStatus = "provider_raw_status"
    }

    private enum EventType: String, Codable {
        case replaceSnapshot = "replace_snapshot"
        case workspaceUpserted = "workspace_upserted"
        case workspaceClosed = "workspace_closed"
        case tabUpserted = "tab_upserted"
        case tabClosed = "tab_closed"
        case paneUpserted = "pane_upserted"
        case paneClosed = "pane_closed"
        case agentUpserted = "agent_upserted"
        case agentClosed = "agent_closed"
        case focusChanged = "focus_changed"
        case titleUpdated = "title_updated"
        case agentStatusUpdated = "agent_status_updated"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EventType.self, forKey: .type)
        switch type {
        case .replaceSnapshot:
            self = .replaceSnapshot(try container.decode(NestedTopologySnapshot.self, forKey: .snapshot))
        case .workspaceUpserted:
            self = .workspaceUpserted(try container.decode(NestedWorkspaceNode.self, forKey: .workspace))
        case .workspaceClosed:
            self = .workspaceClosed(try container.decode(NestedNodeID.self, forKey: .id))
        case .tabUpserted:
            self = .tabUpserted(try container.decode(NestedTabNode.self, forKey: .tab))
        case .tabClosed:
            self = .tabClosed(try container.decode(NestedNodeID.self, forKey: .id))
        case .paneUpserted:
            self = .paneUpserted(try container.decode(NestedPaneNode.self, forKey: .pane))
        case .paneClosed:
            self = .paneClosed(try container.decode(NestedNodeID.self, forKey: .id))
        case .agentUpserted:
            self = .agentUpserted(try container.decode(NestedAgentNode.self, forKey: .agent))
        case .agentClosed:
            self = .agentClosed(try container.decode(NestedNodeID.self, forKey: .id))
        case .focusChanged:
            self = .focusChanged(try container.decode(NestedFocus.self, forKey: .focus))
        case .titleUpdated:
            self = .titleUpdated(
                id: try container.decode(NestedNodeID.self, forKey: .id),
                displayTitle: try container.decode(String.self, forKey: .displayTitle)
            )
        case .agentStatusUpdated:
            self = .agentStatusUpdated(
                id: try container.decode(NestedNodeID.self, forKey: .id),
                status: try container.decode(NestedAgentStatus.self, forKey: .status),
                providerRawStatus: try container.decode(String.self, forKey: .providerRawStatus)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .replaceSnapshot(let snapshot):
            try container.encode(EventType.replaceSnapshot, forKey: .type)
            try container.encode(snapshot, forKey: .snapshot)
        case .workspaceUpserted(let workspace):
            try container.encode(EventType.workspaceUpserted, forKey: .type)
            try container.encode(workspace, forKey: .workspace)
        case .workspaceClosed(let id):
            try container.encode(EventType.workspaceClosed, forKey: .type)
            try container.encode(id, forKey: .id)
        case .tabUpserted(let tab):
            try container.encode(EventType.tabUpserted, forKey: .type)
            try container.encode(tab, forKey: .tab)
        case .tabClosed(let id):
            try container.encode(EventType.tabClosed, forKey: .type)
            try container.encode(id, forKey: .id)
        case .paneUpserted(let pane):
            try container.encode(EventType.paneUpserted, forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .paneClosed(let id):
            try container.encode(EventType.paneClosed, forKey: .type)
            try container.encode(id, forKey: .id)
        case .agentUpserted(let agent):
            try container.encode(EventType.agentUpserted, forKey: .type)
            try container.encode(agent, forKey: .agent)
        case .agentClosed(let id):
            try container.encode(EventType.agentClosed, forKey: .type)
            try container.encode(id, forKey: .id)
        case .focusChanged(let focus):
            try container.encode(EventType.focusChanged, forKey: .type)
            try container.encode(focus, forKey: .focus)
        case .titleUpdated(let id, let displayTitle):
            try container.encode(EventType.titleUpdated, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(displayTitle, forKey: .displayTitle)
        case .agentStatusUpdated(let id, let status, let providerRawStatus):
            try container.encode(EventType.agentStatusUpdated, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(status, forKey: .status)
            try container.encode(providerRawStatus, forKey: .providerRawStatus)
        }
    }
}
