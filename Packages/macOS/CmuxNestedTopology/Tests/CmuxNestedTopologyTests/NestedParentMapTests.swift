import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct NestedParentMapTests {
    @Test func parentMapStableAcrossReshuffledEventBatches() {
        let tree = NestedTopologyFixtures.baseTree()
        let secondPane = NestedPaneNode(
            id: NestedTopologyFixtures.nodeID(kind: .pane, rawID: "w1:p2"),
            tabID: tree.tab.id,
            displayTitle: "Pane 2",
            orderIndex: 1
        )
        let batchA: [NestedTopologyEvent] = [
            .replaceSnapshot(NestedTopologyFixtures.snapshot()),
            .paneUpserted(secondPane),
            .tabUpserted(tree.tab),
        ]
        let batchB: [NestedTopologyEvent] = [
            .tabUpserted(tree.tab),
            .paneUpserted(secondPane),
            .replaceSnapshot(
                NestedTopologyFixtures.snapshot(
                    panes: [tree.pane, secondPane]
                )
            ),
            .paneUpserted(tree.pane),
        ]

        var mapA = NestedParentMap()
        mapA.apply(events: batchA)
        var mapB = NestedParentMap()
        mapB.apply(events: batchB)

        #expect(mapA == mapB)
        #expect(mapA.parent(of: tree.pane.id) == tree.tab.id)
        #expect(mapA.parent(of: secondPane.id) == tree.tab.id)
        #expect(mapA.parent(of: tree.tab.id) == tree.workspace.id)
        #expect(mapA.sortedEdges.map(\.child) == mapB.sortedEdges.map(\.child))
    }

    @Test func closeRemovesDescendantEdges() {
        var map = NestedParentMap()
        let snapshot = NestedTopologyFixtures.snapshot()
        map.replace(with: snapshot)
        let tree = NestedTopologyFixtures.baseTree()
        #expect(map.parent(of: tree.agent.id) == tree.pane.id)
        map.apply(events: [.paneClosed(tree.pane.id)])
        #expect(map.parent(of: tree.pane.id) == nil)
        #expect(map.parent(of: tree.agent.id) == nil)
        #expect(map.parent(of: tree.tab.id) == tree.workspace.id)
    }

    @Test func replaceFromSnapshotIsAuthoritative() {
        var map = NestedParentMap()
        let tree = NestedTopologyFixtures.baseTree()
        map.setParent(of: tree.pane.id, to: NestedTopologyFixtures.nodeID(kind: .tab, rawID: "stale"))
        map.replace(with: NestedTopologyFixtures.snapshot())
        #expect(map.parent(of: tree.pane.id) == tree.tab.id)
    }
}
