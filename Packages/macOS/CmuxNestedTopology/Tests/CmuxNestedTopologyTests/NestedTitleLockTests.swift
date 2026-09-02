import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct NestedTitleLockTests {
    @Test func titleLockSuppressesReducerOverwriteWhenAppliedViaAssociation() throws {
        var reducer = NestedTopologyFixtures.reducer()
        let snapshot = NestedTopologyFixtures.snapshot()
        try reducer.apply(.replaceSnapshot(snapshot))
        let tree = NestedTopologyFixtures.baseTree()

        var store = NestedAssociationStore()
        let key = NestedAssociationKey(
            nodeID: tree.pane.id,
            sessionRawID: "sess-1",
            providerInstanceGeneration: NestedTopologyFixtures.instanceA
        )
        store.lockTitle(for: key, title: "Locked Pane", authority: .user)

        let proposal = store.proposeTitle(for: key, proposed: "Provider Echo")
        #expect(proposal.suppressedOverwrite)
        // Writers must diff before write: only apply when not suppressed.
        if !proposal.suppressedOverwrite {
            try reducer.apply(.titleUpdated(id: tree.pane.id, displayTitle: proposal.title))
        }
        #expect(reducer.snapshot?.pane(id: tree.pane.id)?.displayTitle == "Pane 1")
    }

    @Test func sameTitleUnderLockIsNotAnOverwrite() {
        let key = NestedAssociationKey(
            nodeID: NestedTopologyFixtures.nodeID(kind: .pane, rawID: "w1:p1"),
            sessionRawID: "sess-1",
            providerInstanceGeneration: NestedTopologyFixtures.instanceA
        )
        var store = NestedAssociationStore()
        store.lockTitle(for: key, title: "Same", authority: .hostSurfacePolicy)
        let proposal = store.proposeTitle(for: key, proposed: "Same")
        #expect(proposal.title == "Same")
        #expect(proposal.suppressedOverwrite == false)
    }
}
