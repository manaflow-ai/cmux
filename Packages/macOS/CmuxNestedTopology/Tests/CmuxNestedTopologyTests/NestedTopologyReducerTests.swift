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

        #expect(throws: NestedTopologyError.providerMismatch(
            expected: fixture.provider,
            actual: other.provider
        )) {
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

        #expect(throws: NestedTopologyError.invalidParentKind(
            node: fixture.id("tab-1", kind: .tab),
            parent: fixture.id("pane-1", kind: .pane),
            expected: .workspace
        )) {
            try fixture.snapshot(tabs: [tab], panes: [], agents: [])
        }
    }

    @Test("duplicate identities are rejected at full-snapshot boundaries")
    func rejectsDuplicateSnapshotNodes() {
        let fixture = NestedTopologyTestFixture()

        #expect(throws: NestedTopologyError.self) {
            try fixture.snapshot(
                workspaces: [fixture.workspace(), fixture.workspace()],
                tabs: [],
                panes: [],
                agents: []
            )
        }
    }

    @Test("duplicate creates are idempotent only when their content matches")
    func duplicateCreateBehavior() throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let empty = try fixture.snapshot(workspaces: [], tabs: [], panes: [], agents: [])
        let workspace = fixture.workspace()
        let event = fixture.event(.workspaceCreated(node: workspace))

        let created = try reducer.applying(event, to: empty)
        let duplicated = try reducer.applying(event, to: created)
        #expect(duplicated == created)

        let conflicting = fixture.event(.workspaceCreated(
            node: fixture.workspace(
                order: 7,
                title: NestedNodeTitle(value: "Conflict", authority: .provider)
            )
        ))
        #expect(throws: NestedTopologyError.self) {
            try reducer.applying(conflicting, to: created)
        }
    }

    @Test(
        "duplicate provider creates stay idempotent after local title locks",
        arguments: [
            NestedNodeKind.workspace,
            .tab,
            .pane,
            .agent,
        ]
    )
    func duplicateCreateAfterLocalTitleLock(kind: NestedNodeKind) throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let input: (
            nodeID: NestedNodeID,
            duplicate: NestedTopologyEvent,
            conflict: NestedTopologyEvent
        ) = switch kind {
        case .workspace:
            (
                fixture.id("workspace-1", kind: .workspace),
                fixture.event(.workspaceCreated(node: fixture.workspace())),
                fixture.event(.workspaceCreated(node: fixture.workspace(order: 7)))
            )
        case .tab:
            (
                fixture.id("tab-1", kind: .tab),
                fixture.event(.tabCreated(node: fixture.tab())),
                fixture.event(.tabCreated(node: fixture.tab(order: 7)))
            )
        case .pane:
            (
                fixture.id("pane-1", kind: .pane),
                fixture.event(.paneCreated(node: fixture.pane())),
                fixture.event(.paneCreated(node: fixture.pane(order: 7)))
            )
        case .agent:
            (
                fixture.id("agent-1", kind: .agent),
                fixture.event(.agentCreated(node: fixture.agent())),
                fixture.event(.agentCreated(node: fixture.agent(order: 7)))
            )
        }
        let lock: NestedTopologyTitleChange = switch kind {
        case .workspace, .pane:
            .host(nodeID: input.nodeID, value: "Host lock")
        case .tab, .agent:
            .user(nodeID: input.nodeID, value: "User lock")
        }
        let locked = try reducer.applying(lock, to: fixture.snapshot())

        let duplicated = try reducer.applying(input.duplicate, to: locked)

        #expect(duplicated == locked)
        #expect(throws: NestedTopologyError.self) {
            try reducer.applying(input.conflict, to: locked)
        }
    }

    @Test("updates for unknown nodes request resynchronization instead of creating ghosts")
    func rejectsUnknownUpdate() throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let empty = try fixture.snapshot(workspaces: [], tabs: [], panes: [], agents: [])

        #expect(throws: NestedTopologyError.self) {
            try reducer.applying(
                fixture.event(.workspaceUpdated(node: fixture.workspace())),
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
            fixture.event(.nodeClosed(id: fixture.id("tab-1", kind: .tab))),
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
            fixture.event(.nodeClosed(id: fixture.id("tab-1", kind: .tab))),
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
            fixture.event(.focusChanged(id: fixture.id("agent-1", kind: .agent))),
            to: snapshot
        )
        #expect(agentFocused.focus == NestedTopologyFocus(
            workspaceID: fixture.id("workspace-1", kind: .workspace),
            tabID: fixture.id("tab-1", kind: .tab),
            paneID: fixture.id("pane-1", kind: .pane),
            agentID: fixture.id("agent-1", kind: .agent)
        ))

        let paneFocused = try reducer.applying(
            fixture.event(.focusChanged(id: fixture.id("pane-2", kind: .pane))),
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
                stale.event(.nodeClosed(id: stale.id("pane-1", kind: .pane))),
                to: snapshot
            )
        }
        #expect(throws: NestedTopologyError.self) {
            try NestedTopologyReducer().applying(
                stale.event(.focusChanged(id: nil)),
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
            fixture.event(.workspaceCreated(node: fixture.workspace())),
            fixture.event(.tabUpdated(node: fixture.tab())),
        ]

        #expect(throws: NestedTopologyError.self) {
            try reducer.applying(events, to: empty)
        }
        #expect(empty.workspaces.isEmpty)
    }

    @Test("a production-sized provider tree validates and reduces without special paths")
    func productionSizedFixture() throws {
        let fixture = NestedTopologyTestFixture()
        let workspaces = (0 ..< 20).map {
            fixture.workspace("workspace-\($0)", order: $0)
        }
        let tabs = (0 ..< 100).map {
            fixture.tab(
                "tab-\($0)",
                workspaceRawID: "workspace-\($0 % 20)",
                order: $0 / 20
            )
        }
        let panes = (0 ..< 500).map {
            fixture.pane(
                "pane-\($0)",
                tabRawID: "tab-\($0 % 100)",
                sessionID: "session-\($0)",
                order: $0 / 100
            )
        }
        let agents = (0 ..< 500).map {
            fixture.agent(
                "agent-\($0)",
                paneRawID: "pane-\($0)",
                sessionID: "session-\($0)"
            )
        }
        let snapshot = try fixture.snapshot(
            workspaces: Array(workspaces.reversed()),
            tabs: Array(tabs.reversed()),
            panes: Array(panes.reversed()),
            agents: Array(agents.reversed())
        )

        let updated = try NestedTopologyReducer().applying(
            fixture.event(.agentUpdated(node: fixture.agent(
                "agent-499",
                paneRawID: "pane-499",
                sessionID: "session-499",
                status: NestedAgentStatus(presentation: .done, providerRawValue: "done")
            ))),
            to: snapshot
        )

        #expect(updated.workspaces.count == 20)
        #expect(updated.tabs.count == 100)
        #expect(updated.panes.count == 500)
        #expect(updated.agents.count == 500)
        #expect(updated.agents.first(where: { $0.id.rawID == "agent-499" })?.status.presentation == .done)
    }

    @Test("reparenting a focused node reconciles its focused ancestor chain")
    func focusedReparenting() throws {
        let fixture = NestedTopologyTestFixture()
        let reducer = NestedTopologyReducer()
        let focused = try fixture.snapshot(
            tabs: [
                fixture.tab("tab-1", order: 0),
                fixture.tab("tab-2", order: 1),
            ],
            focus: NestedTopologyFocus(
                workspaceID: fixture.id("workspace-1", kind: .workspace),
                tabID: fixture.id("tab-1", kind: .tab),
                paneID: fixture.id("pane-1", kind: .pane),
                agentID: fixture.id("agent-1", kind: .agent)
            )
        )
        let movedPane = fixture.event(.paneUpdated(node: fixture.pane(tabRawID: "tab-2")))

        let updated = try reducer.applying(movedPane, to: focused)
        #expect(updated.focus.tabID == fixture.id("tab-2", kind: .tab))
        #expect(updated.focus.paneID == fixture.id("pane-1", kind: .pane))
        #expect(updated.focus.agentID == fixture.id("agent-1", kind: .agent))

        let batchUpdated = try reducer.applying([
            movedPane,
            fixture.event(.focusChanged(id: fixture.id("agent-1", kind: .agent))),
        ], to: focused)
        #expect(batchUpdated == updated)
    }

    @Test("no-op events still enforce a stricter reducer policy")
    func noOpEventsEnforceReducerLimits() throws {
        let fixture = NestedTopologyTestFixture()
        let snapshot = try fixture.snapshot(
            workspaces: [fixture.workspace("workspace-1"), fixture.workspace("workspace-2")],
            tabs: [],
            panes: [],
            agents: []
        )
        let reducer = NestedTopologyReducer(limits: fixture.limits(maximumWorkspaces: 1))

        #expect(throws: NestedTopologyError.self) {
            try reducer.applying(
                fixture.event(.workspaceCreated(node: fixture.workspace("workspace-1"))),
                to: snapshot
            )
        }
        #expect(throws: NestedTopologyError.self) {
            try reducer.applying(
                fixture.event(.nodeClosed(id: fixture.id("missing", kind: .workspace))),
                to: snapshot
            )
        }
        #expect(throws: NestedTopologyError.self) {
            try reducer.applying([], to: snapshot)
        }
    }

    @Test("provider event batches are bounded before mutation")
    func eventBatchLimit() throws {
        let fixture = NestedTopologyTestFixture()
        let limits = fixture.limits(maximumEventsPerBatch: 1)
        let snapshot = try fixture.snapshot(
            workspaces: [],
            tabs: [],
            panes: [],
            agents: [],
            limits: limits
        )
        let reducer = NestedTopologyReducer(limits: limits)

        #expect(throws: NestedTopologyError.eventBatchLimitExceeded(actual: 2, maximum: 1)) {
            try reducer.applying([
                fixture.event(.workspaceCreated(node: fixture.workspace("workspace-1"))),
                fixture.event(.workspaceCreated(node: fixture.workspace("workspace-2"))),
            ], to: snapshot)
        }
    }
}
