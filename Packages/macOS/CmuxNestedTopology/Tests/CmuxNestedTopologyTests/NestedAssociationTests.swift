import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct NestedAssociationTests {
    private var key: NestedAssociationKey {
        NestedAssociationKey(
            nodeID: NestedTopologyFixtures.nodeID(kind: .pane, rawID: "w1:p1"),
            sessionRawID: "sess-1",
            providerInstanceGeneration: NestedTopologyFixtures.instanceA
        )
    }

    @Test func heuristicOnceSkipsAfterFirstSuccess() {
        var store = NestedAssociationStore()
        #expect(store.shouldRunHeuristic(for: key))
        let parent = NestedTopologyFixtures.nodeID(kind: .tab, rawID: "w1:t1")
        store.markHeuristicSatisfied(for: key, parentID: parent)
        #expect(store.shouldRunHeuristic(for: key) == false)
        #expect(store.record(for: key)?.heuristicSatisfied == true)
        #expect(store.record(for: key)?.parentID == parent)

        let otherParent = NestedTopologyFixtures.nodeID(kind: .tab, rawID: "w1:t2")
        store.markHeuristicSatisfied(for: key, parentID: otherParent)
        #expect(store.record(for: key)?.parentID == parent)
    }

    @Test func titleLockSuppressesOverwrite() {
        var store = NestedAssociationStore()
        store.lockTitle(for: key, title: "Native Title", authority: .providerNative)
        let proposal = store.proposeTitle(for: key, proposed: "Heuristic Title")
        #expect(proposal.title == "Native Title")
        #expect(proposal.suppressedOverwrite == true)
    }

    @Test func unlockedTitleAcceptsProposal() {
        var store = NestedAssociationStore()
        store.markHeuristicSatisfied(for: key, parentID: nil)
        let proposal = store.proposeTitle(for: key, proposed: "Fresh")
        #expect(proposal.title == "Fresh")
        #expect(proposal.suppressedOverwrite == false)
    }

    @Test func invalidateDropsOtherProviderGenerations() {
        var store = NestedAssociationStore()
        let otherKey = NestedAssociationKey(
            nodeID: NestedTopologyFixtures.nodeID(
                kind: .pane,
                rawID: "w1:p1",
                instance: NestedTopologyFixtures.instanceB
            ),
            sessionRawID: "sess-1",
            providerInstanceGeneration: NestedTopologyFixtures.instanceB
        )
        store.markHeuristicSatisfied(for: key, parentID: nil)
        store.markHeuristicSatisfied(for: otherKey, parentID: nil)
        store.invalidate(providerInstanceGeneration: NestedTopologyFixtures.instanceA)
        #expect(store.record(for: key) != nil)
        #expect(store.record(for: otherKey) == nil)
    }

    @Test func recordResolvedTitleHonorsLock() {
        let record = NestedAssociationRecord(
            key: key,
            heuristicSatisfied: true,
            titleLock: .locked("Locked", authority: .user)
        )
        #expect(record.resolvedTitle(proposed: "Other") == "Locked")
        #expect(record.wouldOverwriteLockedTitle(with: "Other"))
        #expect(record.wouldOverwriteLockedTitle(with: "Locked") == false)
    }
}
