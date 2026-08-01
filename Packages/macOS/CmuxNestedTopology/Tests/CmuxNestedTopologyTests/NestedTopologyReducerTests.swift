import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite("Nested topology reducer")
struct NestedTopologyReducerTests {
    @Test("snapshots use provider order with opaque identity as a deterministic tie breaker")
    func deterministicOrdering() throws {
        let fixture = NestedTopologyTestFixture()
        let snapshot = try fixture.snapshot(
            workspaces: [
                fixture.workspace("workspace-z", order: 1),
                fixture.workspace("workspace-b", order: 0),
                fixture.workspace("workspace-a", order: 0),
            ],
            tabs: [],
            panes: [],
            agents: []
        )

        #expect(snapshot.workspaces.map(\.id.rawID) == [
            "workspace-a",
            "workspace-b",
            "workspace-z",
        ])
    }

    @Test("cross-provider parents are rejected")
    func rejectsCrossProviderParent() {
        let fixture = NestedTopologyTestFixture()
        let other = NestedTopologyTestFixture(
            instanceRawValue: "other",
            generation: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        )
        let tab = NestedTabNode(
            id: fixture.id("tab-1", kind: .tab),
            workspaceID: other.id("workspace-1", kind: .workspace),
            order: 0,
            title: nil
        )

        #expect(throws: NestedTopologyError.self) {
            try fixture.snapshot(tabs: [tab], panes: [], agents: [])
        }
    }

    @Test("cross-kind parents are rejected")
    func rejectsCrossKindParent() {
        let fixture = NestedTopologyTestFixture()
        let tab = NestedTabNode(
            id: fixture.id("tab-1", kind: .tab),
            workspaceID: fixture.id("pane-1", kind: .pane),
            order: 0,
            title: nil
        )

        #expect(throws: NestedTopologyError.self) {
            try fixture.snapshot(tabs: [tab], panes: [], agents: [])
        }
    }

    @Test("duplicate creates are idempotent only when their content matches")
    func duplicateCreateBehavior() throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let empty = try fixture.snapshot(workspaces: [], tabs: [], panes: [], agents: [])
        let workspace = fixture.workspace()
        let event = fixture.event(.workspaceCreated(workspace))

        let created = try reducer.applying(event, to: empty)
        let duplicated = try reducer.applying(event, to: created)
        #expect(duplicated == created)

        let conflicting = fixture.event(.workspaceCreated(
            fixture.workspace(order: 7, title: NestedNodeTitle(value: "Conflict", authority: .provider))
        ))
        #expect(throws: NestedTopologyError.self) {
            try reducer.applying(conflicting, to: created)
        }
    }

    @Test("updates for unknown nodes request resynchronization instead of creating ghosts")
    func rejectsUnknownUpdate() throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let empty = try fixture.snapshot(workspaces: [], tabs: [], panes: [], agents: [])

        #expect(throws: NestedTopologyError.self) {
            try reducer.applying(
                fixture.event(.workspaceUpdated(fixture.workspace())),
                to: empty
            )
        }
    }

    @Test("closing an ancestor cascades and clears invalid focus")
    func closeCascade() throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let focused = try fixture.snapshot(
            focus: NestedTopologyFocus(
                workspaceID: fixture.id("workspace-1", kind: .workspace),
                tabID: fixture.id("tab-1", kind: .tab),
                paneID: fixture.id("pane-1", kind: .pane),
                agentID: fixture.id("agent-1", kind: .agent)
            )
        )

        let result = try reducer.applying(
            fixture.event(.nodeClosed(fixture.id("tab-1", kind: .tab))),
            to: focused
        )

        #expect(result.workspaces.count == 1)
        #expect(result.tabs.isEmpty)
        #expect(result.panes.isEmpty)
        #expect(result.agents.isEmpty)
        #expect(result.focus == NestedTopologyFocus(
            workspaceID: fixture.id("workspace-1", kind: .workspace),
            tabID: nil,
            paneID: nil,
            agentID: nil
        ))

        let duplicateClose = try reducer.applying(
            fixture.event(.nodeClosed(fixture.id("tab-1", kind: .tab))),
            to: result
        )
        #expect(duplicateClose == result)
    }

    @Test("focusing a descendant derives one coherent focus chain")
    func coherentFocusChain() throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let snapshot = try fixture.snapshot(
            panes: [
                fixture.pane("pane-1", order: 0),
                fixture.pane("pane-2", order: 1),
            ],
            agents: [fixture.agent()]
        )

        let agentFocused = try reducer.applying(
            fixture.event(.focusChanged(fixture.id("agent-1", kind: .agent))),
            to: snapshot
        )
        #expect(agentFocused.focus == NestedTopologyFocus(
            workspaceID: fixture.id("workspace-1", kind: .workspace),
            tabID: fixture.id("tab-1", kind: .tab),
            paneID: fixture.id("pane-1", kind: .pane),
            agentID: fixture.id("agent-1", kind: .agent)
        ))

        let paneFocused = try reducer.applying(
            fixture.event(.focusChanged(fixture.id("pane-2", kind: .pane))),
            to: agentFocused
        )
        #expect(paneFocused.focus.paneID == fixture.id("pane-2", kind: .pane))
        #expect(paneFocused.focus.agentID == nil)
    }

    @Test("inconsistent focus chains are rejected at snapshot boundaries")
    func rejectsInconsistentFocus() {
        let fixture = NestedTopologyTestFixture()
        let focus = NestedTopologyFocus(
            workspaceID: fixture.id("workspace-1", kind: .workspace),
            tabID: fixture.id("tab-2", kind: .tab),
            paneID: fixture.id("pane-1", kind: .pane),
            agentID: nil
        )

        #expect(throws: NestedTopologyError.self) {
            try fixture.snapshot(
                tabs: [
                    fixture.tab("tab-1", order: 0),
                    fixture.tab("tab-2", order: 1),
                ],
                focus: focus
            )
        }
    }

    @Test("events from an obsolete provider generation are rejected")
    func rejectsStaleGeneration() throws {
        let fixture = NestedTopologyTestFixture()
        let stale = NestedTopologyTestFixture(
            generation: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )
        let snapshot = try fixture.snapshot()

        #expect(throws: NestedTopologyError.self) {
            try NestedTopologyReducer().applying(
                stale.event(.nodeClosed(stale.id("pane-1", kind: .pane))),
                to: snapshot
            )
        }
    }

    @Test("a failing event batch is atomic")
    func batchAtomicity() throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let empty = try fixture.snapshot(workspaces: [], tabs: [], panes: [], agents: [])
        let events = [
            fixture.event(.workspaceCreated(fixture.workspace())),
            fixture.event(.tabUpdated(fixture.tab())),
        ]

        #expect(throws: NestedTopologyError.self) {
            try reducer.applying(events, to: empty)
        }
        #expect(empty.workspaces.isEmpty)
    }
}
