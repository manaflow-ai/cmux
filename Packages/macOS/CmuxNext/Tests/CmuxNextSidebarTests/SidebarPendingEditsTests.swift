import Testing
@testable import CmuxNextSidebar

/// cx-odqn (Lawrence 2026-10-08, "lots of buggy behavior"): after a drag
/// reorder the list order flipped back and forth (2,3,4 / 4,2,3 / 2,4).
/// The bridge wrote the dropped order into the model, and every live
/// recompute before the home session's echo (a row's title or activity
/// change, or the echo of one step of a multi-step placement) wrote the
/// old or a partial order back. The shown order is now one derivation:
/// the live rows with the pending edits applied in order, until each edit
/// is settled (its commands replied and the store holds their result) or
/// refused.
@Suite struct SidebarPendingEditsTests {
    /// local: a, G1{g1,g2,g3}, b, G2{h1,h2}, c
    private let live = fixture()
    private let moveCFirst = SidebarIntent.reorder([id("c")], to: DropPosition(section: local, index: 0))

    @Test func aLiveRecomputeBeforeTheEchoKeepsTheDroppedOrder() {
        var pending = SidebarPendingEdits()
        _ = pending.add(moveCFirst)
        // The store has not applied the move yet: the live rows are the old order.
        #expect(shape(pending.apply(to: live), local) == "c a G1[g1,g2,g3] b G2[h1,h2]")
    }

    @Test func aPartialEchoShowsTheFinalOrder() {
        var pending = SidebarPendingEdits()
        _ = pending.add(.reorder([id("b"), id("c")], to: DropPosition(section: local, index: 0)))
        // One step of the two-step placement is in the store: b moved, c not yet.
        var partial = live
        SidebarEdits.apply(.reorder([id("b")], to: DropPosition(section: local, index: 0)), to: &partial)
        #expect(shape(pending.apply(to: partial), local) == "b c a G1[g1,g2,g3] G2[h1,h2]")
        #expect(shape(pending.apply(to: partial), local) == shape(pending.apply(to: live), local))
    }

    @Test func aSettledEditLeavesTheLiveOrderAsTheTruth() {
        var pending = SidebarPendingEdits()
        let token = pending.add(moveCFirst)
        pending.settle(token)
        #expect(pending.isEmpty)
        // Another client moved b first after our edit settled: its order wins.
        var later = live
        SidebarEdits.apply(.reorder([id("b")], to: DropPosition(section: local, index: 0)), to: &later)
        #expect(shape(pending.apply(to: later), local) == shape(later, local))
    }

    @Test func editsApplyInOrderAndSettleOneByOne() {
        var pending = SidebarPendingEdits()
        let first = pending.add(moveCFirst)
        _ = pending.add(.reorder([id("a")], to: DropPosition(section: local, index: 0)))
        #expect(shape(pending.apply(to: live), local) == "a c G1[g1,g2,g3] b G2[h1,h2]")
        pending.settle(first)
        #expect(shape(pending.apply(to: live), local) == "a G1[g1,g2,g3] b G2[h1,h2] c")
    }

    @Test func anEditWhoseRowsAreGoneChangesNothing() {
        var pending = SidebarPendingEdits()
        _ = pending.add(.reorder([id("gone")], to: DropPosition(section: local, index: 0)))
        #expect(pending.apply(to: live) == live)
    }
}
