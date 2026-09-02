import Foundation
@testable import CmuxNestedTopology

enum NestedTopologyFixtures {
    static let instanceA = NestedProviderInstanceID(rawValue: "instance-a")
    static let instanceB = NestedProviderInstanceID(rawValue: "instance-b")
    static let attachmentID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let hostSurfaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    static func nodeID(
        kind: NestedNodeKind,
        rawID: String,
        instance: NestedProviderInstanceID = instanceA
    ) -> NestedNodeID {
        NestedNodeID(
            providerKind: .herdr,
            providerInstanceID: instance,
            kind: kind,
            rawID: rawID
        )
    }

    static func handshake(
        instance: NestedProviderInstanceID = instanceA,
        capabilities: NestedCapabilitySet = NestedCapabilitySet(
            capabilities: [.topologySnapshotV1, .topologyEventsV1]
        )
    ) -> NestedProviderHandshake {
        NestedProviderHandshake(
            providerKind: .herdr,
            providerInstanceID: instance,
            version: "1.0.0",
            protocolNumber: 17,
            capabilities: capabilities
        )
    }

    static func baseTree(instance: NestedProviderInstanceID = instanceA) -> (
        workspace: NestedWorkspaceNode,
        tab: NestedTabNode,
        pane: NestedPaneNode,
        agent: NestedAgentNode
    ) {
        let workspace = NestedWorkspaceNode(
            id: nodeID(kind: .workspace, rawID: "w1", instance: instance),
            displayTitle: "Workspace 1",
            orderIndex: 0
        )
        let tab = NestedTabNode(
            id: nodeID(kind: .tab, rawID: "w1:t1", instance: instance),
            workspaceID: workspace.id,
            displayTitle: "Tab 1",
            orderIndex: 0
        )
        let pane = NestedPaneNode(
            id: nodeID(kind: .pane, rawID: "w1:p1", instance: instance),
            tabID: tab.id,
            displayTitle: "Pane 1",
            orderIndex: 0
        )
        let agent = NestedAgentNode(
            id: nodeID(kind: .agent, rawID: "w1:a1", instance: instance),
            paneID: pane.id,
            displayTitle: "Agent 1",
            status: .idle,
            providerRawStatus: "idle",
            orderIndex: 0
        )
        return (workspace, tab, pane, agent)
    }

    static func snapshot(
        instance: NestedProviderInstanceID = instanceA,
        workspaces: [NestedWorkspaceNode]? = nil,
        tabs: [NestedTabNode]? = nil,
        panes: [NestedPaneNode]? = nil,
        agents: [NestedAgentNode]? = nil,
        focus: NestedFocus? = nil
    ) -> NestedTopologySnapshot {
        let tree = baseTree(instance: instance)
        return NestedTopologySnapshot(
            attachmentID: attachmentID,
            hostStableSurfaceID: hostSurfaceID,
            provider: handshake(instance: instance),
            workspaces: workspaces ?? [tree.workspace],
            tabs: tabs ?? [tree.tab],
            panes: panes ?? [tree.pane],
            agents: agents ?? [tree.agent],
            focus: focus ?? NestedFocus(
                workspaceID: tree.workspace.id,
                tabID: tree.tab.id,
                paneID: tree.pane.id,
                agentID: tree.agent.id
            )
        )
    }

    static func reducer(
        instance: NestedProviderInstanceID = instanceA,
        limits: NestedTopologyLimits = .default
    ) -> NestedTopologyReducer {
        NestedTopologyReducer(
            providerKind: .herdr,
            providerInstanceID: instance,
            limits: limits
        )
    }
}
