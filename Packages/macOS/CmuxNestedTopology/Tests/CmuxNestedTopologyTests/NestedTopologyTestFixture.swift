import Foundation
@testable import CmuxNestedTopology

struct NestedTopologyTestFixture {
    let provider: NestedProviderIdentity

    init(
        instanceRawValue: String = "herdr-server-a",
        generation: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    ) {
        provider = NestedProviderIdentity(
            kind: .herdr,
            instanceID: NestedProviderInstanceID(
                rawValue: instanceRawValue,
                generation: generation
            )
        )
    }

    func id(_ rawID: String, kind: NestedNodeKind) -> NestedNodeID {
        NestedNodeID(provider: provider, kind: kind, rawID: rawID)
    }

    func workspace(
        _ rawID: String = "workspace-1",
        order: Int = 0,
        title: NestedNodeTitle? = NestedNodeTitle(value: "Workspace", authority: .provider)
    ) -> NestedWorkspaceNode {
        NestedWorkspaceNode(
            id: id(rawID, kind: .workspace),
            order: order,
            title: title
        )
    }

    func tab(
        _ rawID: String = "tab-1",
        workspaceRawID: String = "workspace-1",
        order: Int = 0,
        title: NestedNodeTitle? = NestedNodeTitle(value: "Tab", authority: .provider)
    ) -> NestedTabNode {
        NestedTabNode(
            id: id(rawID, kind: .tab),
            workspaceID: id(workspaceRawID, kind: .workspace),
            order: order,
            title: title
        )
    }

    func pane(
        _ rawID: String = "pane-1",
        tabRawID: String = "tab-1",
        sessionID: String? = "session-1",
        order: Int = 0,
        title: NestedNodeTitle? = NestedNodeTitle(value: "Pane", authority: .provider),
        associationAuthority: NestedAssociationAuthority = .provider,
        heuristicAlreadySatisfied: Bool = false
    ) -> NestedPaneNode {
        let paneID = id(rawID, kind: .pane)
        return NestedPaneNode(
            id: paneID,
            association: NestedParentAssociation(
                key: NestedAssociationKey(paneID: paneID, sessionID: sessionID),
                tabID: id(tabRawID, kind: .tab),
                authority: associationAuthority,
                heuristicAlreadySatisfied: heuristicAlreadySatisfied
            ),
            order: order,
            title: title
        )
    }

    func agent(
        _ rawID: String = "agent-1",
        paneRawID: String = "pane-1",
        sessionID: String? = "session-1",
        order: Int = 0,
        title: NestedNodeTitle? = NestedNodeTitle(value: "Agent", authority: .provider),
        status: NestedAgentStatus = NestedAgentStatus(
            presentation: .working,
            providerRawValue: "working"
        )
    ) -> NestedAgentNode {
        NestedAgentNode(
            id: id(rawID, kind: .agent),
            paneID: id(paneRawID, kind: .pane),
            sessionID: sessionID,
            order: order,
            title: title,
            status: status
        )
    }

    func snapshot(
        capabilities: NestedProviderCapabilities = NestedProviderCapabilities([
            .topologySnapshot,
            .topologyEvents,
        ]),
        workspaces: [NestedWorkspaceNode]? = nil,
        tabs: [NestedTabNode]? = nil,
        panes: [NestedPaneNode]? = nil,
        agents: [NestedAgentNode]? = nil,
        focus: NestedTopologyFocus = .none,
        limits: NestedTopologyLimits = NestedTopologyLimits()
    ) throws -> NestedTopologySnapshot {
        try NestedTopologySnapshot(
            provider: provider,
            capabilities: capabilities,
            workspaces: workspaces ?? [workspace()],
            tabs: tabs ?? [tab()],
            panes: panes ?? [pane()],
            agents: agents ?? [agent()],
            focus: focus,
            limits: limits
        )
    }

    func event(_ change: NestedTopologyChange) -> NestedTopologyEvent {
        NestedTopologyEvent(provider: provider, change: change)
    }

    func limits(
        maximumWorkspaces: Int? = nil,
        maximumEventsPerBatch: Int? = nil,
        maximumTotalNodes: Int? = nil,
        maximumCapabilities: Int? = nil
    ) -> NestedTopologyLimits {
        let standard = NestedTopologyLimits()
        return NestedTopologyLimits(
            maximumWorkspaces: maximumWorkspaces ?? standard.maximumWorkspaces,
            maximumTabs: standard.maximumTabs,
            maximumPanes: standard.maximumPanes,
            maximumAgents: standard.maximumAgents,
            maximumTotalNodes: maximumTotalNodes ?? standard.maximumTotalNodes,
            maximumEventsPerBatch: maximumEventsPerBatch ?? standard.maximumEventsPerBatch,
            maximumDepth: standard.maximumDepth,
            maximumIdentifierBytes: standard.maximumIdentifierBytes,
            maximumTitleBytes: standard.maximumTitleBytes,
            maximumRawStatusBytes: standard.maximumRawStatusBytes,
            maximumSessionIDBytes: standard.maximumSessionIDBytes,
            maximumCapabilities: maximumCapabilities ?? standard.maximumCapabilities,
            maximumCapabilityBytes: standard.maximumCapabilityBytes
        )
    }
}
