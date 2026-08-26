import Testing
@testable import CmuxNestedTopology

@Suite("Nested topology batch reduction")
struct NestedTopologyBatchReductionTests {
    @Test("a production-sized leaf-close batch publishes one compacted result")
    func productionSizedLeafCloseBatch() throws {
        let fixture = NestedTopologyTestFixture()
        let agentCount = 1_000
        let agents = (0 ..< agentCount).map {
            fixture.agent("agent-\($0)", sessionID: "session-\($0)", order: $0)
        }
        let snapshot = try fixture.snapshot(agents: agents)
        let events = agents.map {
            fixture.event(.nodeClosed(id: $0.id))
        }

        let result = try NestedTopologyReducer().applying(events, to: snapshot)

        #expect(result.workspaces.count == 1)
        #expect(result.tabs.count == 1)
        #expect(result.panes.count == 1)
        #expect(result.agents.isEmpty)
    }

    @Test("a node can close and recreate the same identity within one atomic batch")
    func closeThenRecreateIdentity() throws {
        let fixture = NestedTopologyTestFixture()
        let snapshot = try fixture.snapshot()
        let replacement = fixture.agent(status: NestedAgentStatus(
            presentation: .done,
            providerRawValue: "done"
        ))

        let result = try NestedTopologyReducer().applying([
            fixture.event(.nodeClosed(id: replacement.id)),
            fixture.event(.agentCreated(node: replacement)),
        ], to: snapshot)

        #expect(result.agents == [replacement])
    }

    @Test("deletion preserves the normalized order of surviving nodes")
    func deletionPreservesSurvivorOrder() throws {
        let fixture = NestedTopologyTestFixture()
        let snapshot = try fixture.snapshot(agents: [
            fixture.agent("agent-c", order: 2),
            fixture.agent("agent-a", order: 0),
            fixture.agent("agent-b", order: 1),
        ])

        let result = try NestedTopologyReducer().applying(
            fixture.event(.nodeClosed(id: fixture.id("agent-b", kind: .agent))),
            to: snapshot
        )

        #expect(result.agents.map(\.id.rawID) == ["agent-a", "agent-c"])
    }

    @Test("reparented nodes follow their new cascade ownership within the same batch")
    func reparentingUpdatesCascadeIndexes() throws {
        let fixture = NestedTopologyTestFixture()
        let snapshot = try fixture.snapshot(
            workspaces: [
                fixture.workspace("workspace-1", order: 0),
                fixture.workspace("workspace-2", order: 1),
            ],
            tabs: [
                fixture.tab("tab-1", workspaceRawID: "workspace-1", order: 0),
                fixture.tab("tab-2", workspaceRawID: "workspace-2", order: 0),
            ],
            panes: [
                fixture.pane("pane-1", tabRawID: "tab-1", order: 0),
                fixture.pane("pane-2", tabRawID: "tab-2", order: 0),
            ],
            agents: [fixture.agent("agent-1", paneRawID: "pane-1")]
        )

        let result = try NestedTopologyReducer().applying([
            fixture.event(.tabUpdated(node: fixture.tab(
                "tab-1",
                workspaceRawID: "workspace-2",
                order: 1
            ))),
            fixture.event(.paneUpdated(node: fixture.pane(
                "pane-1",
                tabRawID: "tab-2",
                order: 1
            ))),
            fixture.event(.agentUpdated(node: fixture.agent(
                "agent-1",
                paneRawID: "pane-2"
            ))),
            fixture.event(.nodeClosed(id: fixture.id("workspace-1", kind: .workspace))),
            fixture.event(.nodeClosed(id: fixture.id("tab-1", kind: .tab))),
            fixture.event(.nodeClosed(id: fixture.id("pane-1", kind: .pane))),
        ], to: snapshot)

        #expect(result.workspaces.map(\.id.rawID) == ["workspace-2"])
        #expect(result.tabs.map(\.id.rawID) == ["tab-2"])
        #expect(result.panes.map(\.id.rawID) == ["pane-2"])
        #expect(result.agents.map(\.id.rawID) == ["agent-1"])
        #expect(result.agents[0].paneID == fixture.id("pane-2", kind: .pane))
    }
}
