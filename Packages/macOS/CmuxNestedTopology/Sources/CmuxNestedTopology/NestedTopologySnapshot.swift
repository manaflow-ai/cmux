public import Foundation

/// Immutable provider-owned nested topology snapshot.
///
/// Collections are stored in deterministic order (``orderIndex``, then compound ID).
/// Use ``structuralIdentity`` for equality/diffing that ignores display titles.
public struct NestedTopologySnapshot: Hashable, Codable, Sendable {
    /// Current public encoding version for newly minted snapshots.
    public static let currentEncodingVersion: UInt8 = 1

    /// Encoding schema version.
    public let encodingVersion: UInt8
    /// Attachment that owns this snapshot.
    public let attachmentID: UUID
    /// Host cmux stable surface identity.
    public let hostStableSurfaceID: UUID
    /// Provider handshake metadata.
    public let provider: NestedProviderHandshake
    /// Workspaces in deterministic order.
    public let workspaces: [NestedWorkspaceNode]
    /// Tabs in deterministic order.
    public let tabs: [NestedTabNode]
    /// Panes in deterministic order.
    public let panes: [NestedPaneNode]
    /// Agents in deterministic order.
    public let agents: [NestedAgentNode]
    /// Focused nested nodes.
    public let focus: NestedFocus

    enum CodingKeys: String, CodingKey {
        case encodingVersion = "encoding_version"
        case attachmentID = "attachment_id"
        case hostStableSurfaceID = "host_stable_surface_id"
        case provider
        case workspaces
        case tabs
        case panes
        case agents
        case focus
    }

    /// Creates a snapshot and sorts collections deterministically.
    public init(
        encodingVersion: UInt8 = NestedTopologySnapshot.currentEncodingVersion,
        attachmentID: UUID,
        hostStableSurfaceID: UUID,
        provider: NestedProviderHandshake,
        workspaces: [NestedWorkspaceNode],
        tabs: [NestedTabNode],
        panes: [NestedPaneNode],
        agents: [NestedAgentNode],
        focus: NestedFocus
    ) {
        self.encodingVersion = encodingVersion
        self.attachmentID = attachmentID
        self.hostStableSurfaceID = hostStableSurfaceID
        self.provider = provider
        self.workspaces = NestedTopologyOrdering().sortedWorkspaces(workspaces)
        self.tabs = NestedTopologyOrdering().sortedTabs(tabs)
        self.panes = NestedTopologyOrdering().sortedPanes(panes)
        self.agents = NestedTopologyOrdering().sortedAgents(agents)
        self.focus = focus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodingVersion = try container.decodeIfPresent(UInt8.self, forKey: .encodingVersion)
            ?? NestedTopologySnapshot.currentEncodingVersion
        let attachmentID = try container.decode(UUID.self, forKey: .attachmentID)
        let hostStableSurfaceID = try container.decode(UUID.self, forKey: .hostStableSurfaceID)
        let provider = try container.decode(NestedProviderHandshake.self, forKey: .provider)
        let workspaces = try container.decodeIfPresent([NestedWorkspaceNode].self, forKey: .workspaces) ?? []
        let tabs = try container.decodeIfPresent([NestedTabNode].self, forKey: .tabs) ?? []
        let panes = try container.decodeIfPresent([NestedPaneNode].self, forKey: .panes) ?? []
        let agents = try container.decodeIfPresent([NestedAgentNode].self, forKey: .agents) ?? []
        let focus = try container.decode(NestedFocus.self, forKey: .focus)
        self.init(
            encodingVersion: encodingVersion,
            attachmentID: attachmentID,
            hostStableSurfaceID: hostStableSurfaceID,
            provider: provider,
            workspaces: workspaces,
            tabs: tabs,
            panes: panes,
            agents: agents,
            focus: focus
        )
    }

    /// Structural identity excluding display titles.
    public var structuralIdentity: NestedTopologyStructuralIdentity {
        NestedTopologyStructuralIdentity(
            attachmentID: attachmentID,
            hostStableSurfaceID: hostStableSurfaceID,
            providerKind: provider.providerKind,
            providerInstanceID: provider.providerInstanceID,
            workspaceIDs: workspaces.map(\.id),
            tabs: tabs.map {
                NestedStructuralTab(id: $0.id, workspaceID: $0.workspaceID, orderIndex: $0.orderIndex)
            },
            panes: panes.map {
                NestedStructuralPane(id: $0.id, tabID: $0.tabID, orderIndex: $0.orderIndex)
            },
            agents: agents.map {
                NestedStructuralAgent(
                    id: $0.id,
                    paneID: $0.paneID,
                    status: $0.status,
                    orderIndex: $0.orderIndex
                )
            },
            focus: focus
        )
    }

    /// Whether two snapshots are structurally equal, ignoring display titles.
    public func structurallyEquals(_ other: NestedTopologySnapshot) -> Bool {
        structuralIdentity == other.structuralIdentity
    }

    /// Lookup helpers used by the reducer and association helpers.
    public func workspace(id: NestedNodeID) -> NestedWorkspaceNode? {
        workspaces.first(where: { $0.id == id })
    }

    /// Returns the tab with the given compound ID.
    public func tab(id: NestedNodeID) -> NestedTabNode? {
        tabs.first(where: { $0.id == id })
    }

    /// Returns the pane with the given compound ID.
    public func pane(id: NestedNodeID) -> NestedPaneNode? {
        panes.first(where: { $0.id == id })
    }

    /// Returns the agent with the given compound ID.
    public func agent(id: NestedNodeID) -> NestedAgentNode? {
        agents.first(where: { $0.id == id })
    }

    /// Whether any node with the compound ID exists.
    public func contains(_ id: NestedNodeID) -> Bool {
        workspace(id: id) != nil
            || tab(id: id) != nil
            || pane(id: id) != nil
            || agent(id: id) != nil
    }
}
