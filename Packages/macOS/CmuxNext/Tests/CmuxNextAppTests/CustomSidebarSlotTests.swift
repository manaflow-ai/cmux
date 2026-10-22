@testable import CmuxNextApps
import Foundation
import Observation
import Testing

/// A custom sidebar (`cmux.sidebar/1`, plans/cmux-next/custom-sidebar-DESIGN.md) re-renders only
/// the scene nodes an op batch touched: one row's update must not invalidate the other 499 rows.
@MainActor
@Suite struct CustomSidebarSlotTests {
    /// `list` (LazyVStack) > `each` (ForEach, inline) > `r0...r{n-1}` (Text).
    static func rows(_ count: Int) -> AppSceneModel {
        let model = AppSceneModel()
        var ops: [AppSceneOp] = [.create(id: "list", type: "LazyVStack", props: [:]), .create(id: "each", type: "ForEach", props: [:])]
        for index in 0..<count { ops.append(.create(id: "r\(index)", type: "Text", props: ["text": .string("row \(index)")])) }
        ops += [.children(id: "each", children: (0..<count).map { "r\($0)" }), .children(id: "list", children: ["each"]), .root(id: "list")]
        model.apply(ops)
        return model
    }

    /// The node slots whose observers fired while `change` ran.
    static func invalidated(_ model: AppSceneModel, _ ids: [String], during change: () -> Void) -> Set<String> {
        let fired = Fired()
        for id in ids {
            let slot = model.slot(id)
            withObservationTracking({ _ = (slot.node, slot.children) }, onChange: { fired.insert(id) })
        }
        change()
        return fired.ids
    }

    @Test func oneRowUpdateInvalidatesOnlyThatRow() {
        let model = Self.rows(500)
        let ids = ["list", "each"] + (0..<500).map { "r\($0)" }
        let fired = Self.invalidated(model, ids) { model.apply([.update(id: "r250", props: ["text": .string("changed")])]) }
        #expect(fired == ["r250"])
        #expect(model.slot("r250").node?.string("text") == "changed")
    }

    @Test func aChildrenChangeInvalidatesTheParentAndItsInlineAncestorsOnly() {
        let model = Self.rows(10)
        let ids = ["list", "each"] + (0..<10).map { "r\($0)" }
        let order = (0..<10).reversed().map { "r\($0)" }
        let fired = Self.invalidated(model, ids) { model.apply([.children(id: "each", children: order)]) }
        #expect(fired == ["each", "list"])
        #expect(model.slot("list").children == order, "the stack lays out the ForEach's rows inline")
    }

    @Test func aRemovedNodeClearsItsSlotAndItsParents() {
        let model = Self.rows(4)
        let ids = ["list", "each", "r0", "r1", "r2", "r3"]
        let fired = Self.invalidated(model, ids) { model.apply([.remove(id: "r2")]) }
        #expect(fired == ["r2", "each", "list"])
        #expect(model.slot("r2").node == nil)
        #expect(model.slot("list").children == ["r0", "r1", "r3"])
    }

    @Test func wholeSceneObserversFollowTheRevision() {
        let model = Self.rows(3)
        let fired = Fired()
        withObservationTracking({ _ = model.revision }, onChange: { fired.insert("revision") })
        model.apply([.update(id: "r1", props: ["text": .string("x")])])
        #expect(fired.ids == ["revision"])
        #expect(model.scene["r1"]?.string("text") == "x")
    }

    @Test func anUnchangedUpdateInvalidatesNothing() {
        let model = Self.rows(3)
        let fired = Self.invalidated(model, ["list", "each", "r0", "r1", "r2"]) {
            model.apply([.update(id: "r1", props: ["text": .string("row 1")])])
        }
        #expect(fired.isEmpty)
    }
}

// Observation calls onChange synchronously on the mutating (main) thread; the box only
// collects ids inside one test, so no two threads touch it.
private nonisolated final class Fired: @unchecked Sendable {
    private(set) var ids: Set<String> = []
    func insert(_ id: String) { ids.insert(id) }
}
