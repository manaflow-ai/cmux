@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// `BulkClosePlan`: which objects of one close gesture go in the one `layout.bulk` request (one
/// Reopen Closed step), and `WorkspaceGroupClose.matching`: the undo toast of a bulk workspace
/// close finds its one closed item of several members.
@MainActor struct BulkClosePlanTests {
    private struct Object: Equatable {
        var name: String
        var id: ResourceID?
        var tabs = true
    }

    private let a = Object(name: "a", id: ResourceID("ws_a")), b = Object(name: "b", id: ResourceID("ws_b")),
                c = Object(name: "c", id: ResourceID("ws_c"))

    private func plan(_ objects: [Object], bulk: Bool = true) -> BulkClosePlan<Object> {
        BulkClosePlan(objects, servesBulk: bulk, id: \.id, hasTabs: \.tabs)
    }

    @Test func severalObjectsGoInOneRequest() {
        let plan = plan([a, b, c])
        #expect(plan.bulk.map(\.object) == [a, b, c])
        #expect(plan.bulk.map(\.id) == [ResourceID("ws_a"), ResourceID("ws_b"), ResourceID("ws_c")])
        #expect(plan.each.isEmpty)
    }

    @Test func anEmptyObjectOrOneWithNoIdClosesAlone() {
        let empty = Object(name: "empty", id: ResourceID("ws_e"), tabs: false), unnamed = Object(name: "unnamed", id: nil)
        let plan = plan([a, empty, b, unnamed])
        #expect(plan.bulk.map(\.object) == [a, b])
        #expect(plan.each == [empty, unnamed])
    }

    @Test func oneObjectOrAnOlderDaemonKeepsTheOwnCloses() {
        #expect(plan([a]).bulk.isEmpty)
        #expect(plan([a]).each == [a])
        #expect(plan([a, b], bulk: false).bulk.isEmpty)
        #expect(plan([a, b], bulk: false).each == [a, b])
        // Only one of them can go in a bulk request: no request for one.
        let empty = Object(name: "empty", id: ResourceID("ws_e"), tabs: false)
        #expect(plan([a, empty]).bulk.isEmpty)
        #expect(plan([a, empty]).each == [a, empty])
    }

    @Test func theUndoOfABulkCloseFindsItsOneItemOfSeveralMembers() {
        let bulk = ClosedItem(id: "closed_bulk", kind: .workspace, name: "x", memberNames: ["x", "y", "z"])
        let older = ClosedItem(id: "closed_old", kind: .workspace, name: "x", memberNames: ["x"])
        let found = WorkspaceGroupClose.matching(names: ["x", "y", "z"], group: nil, fresh: [bulk, older])
        #expect(found.workspaces == ["closed_bulk"])
        #expect(found.missing.isEmpty)
    }

    @Test func theUndoOfAnOlderDaemonsCloseFindsOneItemPerWorkspace() {
        let items = ["x", "y"].map { (name: String) in ClosedItem(id: "closed_\(name)", kind: .workspace, name: name) }
        let found = WorkspaceGroupClose.matching(names: ["x", "y", "z"], group: nil, fresh: items)
        #expect(found.workspaces == ["closed_x", "closed_y"])
        #expect(found.missing == ["z"], "z has not arrived yet")
    }
}
