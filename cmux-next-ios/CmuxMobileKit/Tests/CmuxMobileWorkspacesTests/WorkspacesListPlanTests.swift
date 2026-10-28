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
