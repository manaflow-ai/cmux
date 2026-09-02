import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct NestedTopologyReducerTests {
    @Test func malformedParentFailsDeterministically() throws {
        var reducer = NestedTopologyFixtures.reducer()
        try reducer.apply(.replaceSnapshot(NestedTopologyFixtures.snapshot()))
        let orphan = NestedTabNode(
            id: NestedTopologyFixtures.nodeID(kind: .tab, rawID: "orphan"),
            workspaceID: NestedTopologyFixtures.nodeID(kind: .workspace, rawID: "missing"),
            displayTitle: "Orphan",
            orderIndex: 1
        )
        #expect(throws: NestedTopologyValidationError.self) {
            try reducer.apply(.tabUpserted(orphan))
        }
    }

    @Test func parentWrongKindFails() throws {
        var reducer = NestedTopologyFixtures.reducer()
        let tree = NestedTopologyFixtures.baseTree()
        try reducer.apply(.replaceSnapshot(NestedTopologyFixtures.snapshot()))
        let bad = NestedPaneNode(
            id: NestedTopologyFixtures.nodeID(kind: .pane, rawID: "bad"),
            tabID: tree.workspace.id, // workspace is wrong parent kind
            displayTitle: "Bad",
            orderIndex: 1
        )
        #expect(throws: NestedTopologyValidationError.self) {
            try reducer.apply(.paneUpserted(bad))
        }
    }

    @Test func duplicateEventUpsertIsIdempotent() throws {
        var reducer = NestedTopologyFixtures.reducer()
        let snapshot = NestedTopologyFixtures.snapshot()
        try reducer.apply(.replaceSnapshot(snapshot))
        let tree = NestedTopologyFixtures.baseTree()
        let changed = try reducer.apply(.paneUpserted(tree.pane))
        #expect(changed == false)
        #expect(reducer.snapshot == snapshot)
    }

    @Test func closeCascadeRemovesDescendantsAndScrubsFocus() throws {
        var reducer = NestedTopologyFixtures.reducer()
        let snapshot = NestedTopologyFixtures.snapshot()
        try reducer.apply(.replaceSnapshot(snapshot))
        let tree = NestedTopologyFixtures.baseTree()
        let changed = try reducer.apply(.workspaceClosed(tree.workspace.id))
        #expect(changed == true)
        let next = try #require(reducer.snapshot)
        #expect(next.workspaces.isEmpty)
        #expect(next.tabs.isEmpty)
        #expect(next.panes.isEmpty)
        #expect(next.agents.isEmpty)
        #expect(next.focus == .empty)
    }

    @Test func duplicateCloseIsIdempotent() throws {
        var reducer = NestedTopologyFixtures.reducer()
        let tree = NestedTopologyFixtures.baseTree()
        try reducer.apply(.replaceSnapshot(NestedTopologyFixtures.snapshot()))
        _ = try reducer.apply(.agentClosed(tree.agent.id))
        let second = try reducer.apply(.agentClosed(tree.agent.id))
        #expect(second == false)
    }

    @Test func focusInvariantsRejectUnknownNodes() throws {
        var reducer = NestedTopologyFixtures.reducer()
        try reducer.apply(.replaceSnapshot(NestedTopologyFixtures.snapshot()))
        let bogus = NestedFocus(
            workspaceID: NestedTopologyFixtures.nodeID(kind: .workspace, rawID: "nope")
        )
        #expect(throws: NestedTopologyValidationError.self) {
            try reducer.apply(.focusChanged(bogus))
        }
    }

    @Test func focusInvariantsRejectWrongKind() throws {
        var reducer = NestedTopologyFixtures.reducer()
        let tree = NestedTopologyFixtures.baseTree()
        try reducer.apply(.replaceSnapshot(NestedTopologyFixtures.snapshot()))
        let bogus = NestedFocus(workspaceID: tree.pane.id)
        #expect(throws: NestedTopologyValidationError.self) {
            try reducer.apply(.focusChanged(bogus))
        }
    }

    @Test func boundsRejectOversizedTitle() throws {
        var limits = NestedTopologyLimits.default
        limits.maxDisplayTitleUTF8ByteCount = 4
        var reducer = NestedTopologyFixtures.reducer(limits: limits)
        let tree = NestedTopologyFixtures.baseTree()
        let shortSnapshot = NestedTopologyFixtures.snapshot(
            workspaces: [
                NestedWorkspaceNode(id: tree.workspace.id, displayTitle: "W", orderIndex: 0),
            ],
            tabs: [
                NestedTabNode(
                    id: tree.tab.id,
                    workspaceID: tree.workspace.id,
                    displayTitle: "T",
                    orderIndex: 0
                ),
            ],
            panes: [
                NestedPaneNode(
                    id: tree.pane.id,
                    tabID: tree.tab.id,
                    displayTitle: "P",
                    orderIndex: 0
                ),
            ],
            agents: [
                NestedAgentNode(
                    id: tree.agent.id,
                    paneID: tree.pane.id,
                    displayTitle: "A",
                    status: .idle,
                    providerRawStatus: "idle",
                    orderIndex: 0
                ),
            ]
        )
        try reducer.apply(.replaceSnapshot(shortSnapshot))
        #expect(throws: NestedTopologyValidationError.self) {
            try reducer.apply(.titleUpdated(id: tree.pane.id, displayTitle: "too-long"))
        }
    }

    @Test func boundsRejectExcessiveCount() throws {
        var limits = NestedTopologyLimits.default
        limits.maxTabs = 1
        var reducer = NestedTopologyFixtures.reducer(limits: limits)
        try reducer.apply(.replaceSnapshot(NestedTopologyFixtures.snapshot()))
        let tree = NestedTopologyFixtures.baseTree()
        let extra = NestedTabNode(
            id: NestedTopologyFixtures.nodeID(kind: .tab, rawID: "w1:t2"),
            workspaceID: tree.workspace.id,
            displayTitle: "Tab 2",
            orderIndex: 1
        )
        #expect(throws: NestedTopologyValidationError.self) {
            try reducer.apply(.tabUpserted(extra))
        }
    }

    @Test func invalidStatusFailsDeterministically() throws {
        var reducer = NestedTopologyFixtures.reducer()
        try reducer.apply(.replaceSnapshot(NestedTopologyFixtures.snapshot()))
        let tree = NestedTopologyFixtures.baseTree()
        #expect(throws: NestedTopologyValidationError.self) {
            try reducer.apply(
                .agentStatusUpdated(id: tree.agent.id, status: .working, providerRawStatus: "idle")
            )
        }
        #expect(throws: NestedTopologyValidationError.self) {
            try reducer.apply(
                .agentStatusUpdated(id: tree.agent.id, status: .idle, providerRawStatus: "")
            )
        }
    }

    @Test func deterministicOrderingIndependentOfInputShuffle() throws {
        let tree = NestedTopologyFixtures.baseTree()
        let secondTab = NestedTabNode(
            id: NestedTopologyFixtures.nodeID(kind: .tab, rawID: "w1:t0"),
            workspaceID: tree.workspace.id,
            displayTitle: "Tab 0",
            orderIndex: 0
        )
        let first = NestedTopologyFixtures.snapshot(tabs: [tree.tab, secondTab])
        let second = NestedTopologyFixtures.snapshot(tabs: [secondTab, tree.tab])
        #expect(first.tabs.map(\.id) == second.tabs.map(\.id))
        #expect(first.tabs[0].id.rawID == "w1:t0")
    }

    @Test func structuralEqualityIgnoresDisplayTitle() throws {
        let base = NestedTopologyFixtures.snapshot()
        var renamedTree = NestedTopologyFixtures.baseTree()
        renamedTree.pane.displayTitle = "Renamed"
        let renamed = NestedTopologyFixtures.snapshot(
            workspaces: [renamedTree.workspace],
            tabs: [renamedTree.tab],
            panes: [renamedTree.pane],
            agents: [renamedTree.agent],
            focus: base.focus
        )
        #expect(base != renamed)
        #expect(base.structurallyEquals(renamed))
    }

    @Test func providerInstanceMismatchOnSnapshotFails() {
        var reducer = NestedTopologyFixtures.reducer(instance: NestedTopologyFixtures.instanceA)
        let foreign = NestedTopologyFixtures.snapshot(instance: NestedTopologyFixtures.instanceB)
        #expect(throws: NestedTopologyValidationError.self) {
            try reducer.apply(.replaceSnapshot(foreign))
        }
    }
}
