import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// A live update costs O(changed rows): the list reconfigures only the rows
/// whose value changed, applies a new snapshot only when the order or the
/// membership changed, and animates only when rows came or went.
@Suite struct WorkspacesListPlanTests {
    typealias Section = ListSectionIDs

    @Test func nothingChangedDoesNothing() {
        let sections = [Section(id: "recent", items: ["a", "b", "c"])]
        let items = ["a": 1, "b": 2, "c": 3]
        let plan = ListApplyPlan.make(old: sections, oldItems: items, new: sections, newItems: items)
        #expect(plan == ListApplyPlan(orderChanged: false, membershipChanged: false, reconfigure: []))
        #expect(plan.isEmpty)
    }

    @Test func oneChangedRowIsTheOnlyReconfigure() {
        let sections = [Section(id: "recent", items: ["a", "b", "c"])]
        let plan = ListApplyPlan.make(old: sections, oldItems: ["a": 1, "b": 2, "c": 3],
                                      new: sections, newItems: ["a": 1, "b": 20, "c": 3])
        #expect(plan == ListApplyPlan(orderChanged: false, membershipChanged: false, reconfigure: ["b"]))
    }

    @Test func aMoveChangesTheOrderNotTheMembership() {
        let plan = ListApplyPlan.make(old: [Section(id: "recent", items: ["a", "b", "c"])], oldItems: ["a": 1, "b": 2, "c": 3],
                                      new: [Section(id: "recent", items: ["c", "a", "b"])], newItems: ["a": 1, "b": 2, "c": 30])
        #expect(plan.orderChanged)
        #expect(!plan.membershipChanged)
        #expect(plan.reconfigure == ["c"])
    }

    @Test func aRowMovingBetweenSectionsIsAnOrderChange() {
        let plan = ListApplyPlan.make(old: [Section(id: "needs", items: ["a"]), Section(id: "recent", items: ["b"])],
                                      oldItems: ["a": 1, "b": 2],
                                      new: [Section(id: "needs", items: []), Section(id: "recent", items: ["a", "b"])],
                                      newItems: ["a": 1, "b": 2])
        #expect(plan.orderChanged)
        #expect(!plan.membershipChanged)
    }

    @Test func comingAndGoingIsAMembershipChange() {
        let plan = ListApplyPlan.make(old: [Section(id: "recent", items: ["a", "b"])], oldItems: ["a": 1, "b": 2],
                                      new: [Section(id: "recent", items: ["a", "z"])], newItems: ["a": 1, "z": 9])
        #expect(plan.orderChanged)
        #expect(plan.membershipChanged)
        // A new row is configured by the snapshot, never reconfigured.
        #expect(plan.reconfigure.isEmpty)
    }

    /// The diffable source refuses a repeated id: the model keeps the first.
    @Test func repeatedIDsKeepTheFirst() {
        let sections = ListSectionIDs.unique([Section(id: "needs", items: ["a", "b"]), Section(id: "fold", items: ["b", "c", "c"])])
        #expect(sections == [Section(id: "needs", items: ["a", "b"]), Section(id: "fold", items: ["c"])])
    }
}

#if os(iOS)
/// A live reorder applies as the moved items only; replaying them on the old
/// order gives the new one.
@MainActor
@Suite struct WorkspacesListMoveTests {
    private func replay(_ old: [ListSectionIDs], _ moves: [WorkspacesListController.Move]) -> [ListSectionIDs] {
        var sections = old
        for move in moves {
            for index in sections.indices { sections[index].items.removeAll { $0 == move.id } }
            guard let s = sections.firstIndex(where: { $0.id == move.section }) else { continue }
            if let before = move.before, let at = sections[s].items.firstIndex(of: before) {
                sections[s].items.insert(move.id, at: at)
            } else {
                sections[s].items.append(move.id)
            }
        }
        return sections
    }

    @Test func aRowToTheTopIsOneMove() throws {
        let old = [ListSectionIDs(id: "recent", items: (0..<200).map { "w\($0)" })]
        var items = old[0].items
        items.insert(items.remove(at: 137), at: 1)
        let new = [ListSectionIDs(id: "recent", items: items)]
        let moves = try #require(WorkspacesListController.moves(from: old, to: new))
        #expect(moves.count == 1)
        #expect(replay(old, moves) == new)
    }

    @Test func aRowToTheEndAndAShuffleReplay() throws {
        let old = [ListSectionIDs(id: "a", items: ["1", "2", "3", "4"]), ListSectionIDs(id: "b", items: ["5", "6"])]
        let new = [ListSectionIDs(id: "a", items: ["2", "3", "4", "1"]), ListSectionIDs(id: "b", items: ["6", "5"])]
        let moves = try #require(WorkspacesListController.moves(from: old, to: new))
        #expect(replay(old, moves) == new)
    }

    @Test func aBigShuffleIsANewSnapshot() {
        let old = [ListSectionIDs(id: "a", items: (0..<40).map(String.init))]
        let new = [ListSectionIDs(id: "a", items: (0..<40).reversed().map(String.init))]
        #expect(WorkspacesListController.moves(from: old, to: new) == nil)
        // Rows crossing sections are a new snapshot too.
        #expect(WorkspacesListController.moves(from: [ListSectionIDs(id: "a", items: ["1"]), ListSectionIDs(id: "b", items: ["2"])],
                                               to: [ListSectionIDs(id: "a", items: ["1", "2"]), ListSectionIDs(id: "b", items: [])]) == nil)
    }
}
#endif
