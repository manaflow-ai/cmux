@testable import CmuxNextTabs
import Testing

/// Leo 2026-10-19: "we need to be able to multi select those tabs". Chrome's tab multi-selection
/// (`ui::ListSelectionModel`, `TabStripModel::MoveSelectedTabsTo`): Cmd-click toggles a tab,
/// Shift-click selects the range from the anchor, a plain click goes back to one tab, the
/// selection follows closes and an active tab changed from elsewhere, and a move keeps the
/// selected tabs' order with pinned and unpinned tabs each in their section.
@MainActor struct TabMultiSelectionTests {
    /// p0 p1 pinned, then t2 t3 t4 t5; t2 is active.
    private func model(active: TabID = "t2") -> TabStripModel {
        let tabs = (0..<6).map { TabItem(id: TabID($0 < 2 ? "p\($0)" : "t\($0)"), title: "Tab \($0)", isPinned: $0 < 2) }
        return TabStripModel(tabs: tabs, selectedID: active)
    }

    private func ids(_ raw: String...) -> [TabID] { raw.map { TabID($0) } }

    /// Applies a click like the strip does: the returned tab becomes active.
    private func click(_ model: TabStripModel, _ id: TabID, _ kind: TabMultiSelection.Click) {
        if let next = model.click(id, kind) { model.selectedID = next }
    }

    @Test func cmdClickAddsATabAndMakesItActive() {
        let strip = model()
        click(strip, "t4", .toggle)
        #expect(strip.selectedID == TabID("t4"))
        #expect(strip.selectedTabIDs == ids("t2", "t4"))
        #expect(strip.multiSelection.isMultiple)
    }

    @Test func cmdClickTakesASelectedTabOutAndTheNextSelectedTabBecomesActive() {
        let strip = model()
        click(strip, "t3", .toggle)
        click(strip, "t5", .toggle)
        #expect(strip.selectedTabIDs == ids("t2", "t3", "t5"))
        // t5 is active; taking it out activates the nearest selected tab (none after it: t3).
        click(strip, "t5", .toggle)
        #expect(strip.selectedID == TabID("t3"))
        #expect(strip.selectedTabIDs == ids("t2", "t3"))
        // A selected tab that is not active leaves without a switch; one tab left is no selection.
        click(strip, "t2", .toggle)
        #expect(strip.selectedID == TabID("t3"))
        #expect(!strip.multiSelection.isMultiple)
        #expect(strip.selectedTabIDs == ids("t3"))
    }

    @Test func cmdClickOnTheOnlySelectedTabKeepsIt() {
        let strip = model()
        #expect(strip.click("t2", .toggle) == nil)
        #expect(strip.selectedTabIDs == ids("t2"))
    }

    @Test func shiftClickSelectsTheRangeFromTheAnchor() {
        let strip = model()
        click(strip, "t5", .range)
        #expect(strip.selectedID == TabID("t5"))
        #expect(strip.selectedTabIDs == ids("t2", "t3", "t4", "t5"))
        // The anchor stays where the range began: a second Shift-click narrows it.
        click(strip, "t3", .range)
        #expect(strip.selectedTabIDs == ids("t2", "t3"))
    }

    @Test func aRangeCrossesFromThePinnedTabsIntoTheRest() {
        let strip = model(active: "p1")
        click(strip, "t3", .range)
        #expect(strip.selectedTabIDs == ids("p1", "t2", "t3"))
    }

    @Test func cmdShiftClickAddsARangeToTheSelection() {
        let strip = model(active: "p0")
        click(strip, "t4", .toggle)
        click(strip, "t2", .addRange)
        // The range runs from the anchor (t4, the last Cmd-click) and joins p0.
        #expect(strip.selectedTabIDs == ids("p0", "t2", "t3", "t4"))
    }

    @Test func aPlainClickSelectsOneTabAgain() {
        let strip = model()
        click(strip, "t4", .range)
        click(strip, "p0", .plain)
        #expect(strip.selectedID == TabID("p0"))
        #expect(!strip.multiSelection.isMultiple)
        #expect(strip.selectedTabIDs == ids("p0"))
        strip.selectedID = "t3"
        click(strip, "t5", .range)
        strip.clearMultiSelection()
        #expect(strip.selectedTabIDs == ids("t5"))
    }

    @Test func closedTabsLeaveTheSelection() {
        let strip = model()
        click(strip, "t3", .toggle)
        click(strip, "t5", .toggle)
        strip.tabs.removeAll { $0.id == TabID("t3") }
        #expect(strip.selectedTabIDs == ids("t2", "t5"))
        strip.tabs.removeAll { $0.id == TabID("t2") }
        #expect(!strip.multiSelection.isMultiple, "one selected tab left is no selection")
    }

    @Test func anActiveTabChangedFromElsewhereEndsTheSelectionUnlessItIsSelected() {
        let strip = model()
        click(strip, "t4", .range)
        strip.selectedID = "t3"
        #expect(strip.selectedTabIDs == ids("t2", "t3", "t4"), "a switch inside the selection keeps it")
        strip.selectedID = "p0"
        #expect(strip.selectedTabIDs == ids("p0"), "a switch to another tab ends it")
    }

    @Test func aStripWithoutMultiSelectionTakesEveryClickAsPlain() {
        let tabs = (0..<3).map { TabItem(id: TabID("s\($0)"), title: "Screen \($0)") }
        let strip = TabStripModel(tabs: tabs, selectedID: "s0", allowsMultiSelection: false)
        click(strip, "s2", .toggle)
        #expect(strip.selectedID == TabID("s2"))
        #expect(!strip.multiSelection.isMultiple)
    }

    // MARK: Actions on the selection

    @Test func theMenuActsOnTheSelectionWithTheClickedTabFirst() {
        let strip = model()
        click(strip, "t4", .toggle)
        click(strip, "p1", .toggle)
        #expect(strip.contextSelection(for: "t4") == ids("t4", "p1", "t2"))
        #expect(strip.actingTabs(for: "t4") == ids("p1", "t2", "t4"))
        // A tab outside the selection is acted on alone.
        #expect(strip.contextSelection(for: "t5") == ids("t5"))
        #expect(strip.actingTabs(for: "t5") == ids("t5"))
    }

    @Test func closeOtherTabsKeepsTheSelectionAndThePinnedTabs() {
        let strip = model()
        click(strip, "t4", .toggle)
        #expect(strip.closedByCloseOthers(keepingAll: strip.selectedTabIDs) == ids("t3", "t5"))
    }

    @Test func pinPinsEveryTabUnlessAllArePinned() {
        let strip = model()
        #expect(strip.pinsAll(ids("p0", "t2")))
        #expect(!strip.pinsAll(ids("p0", "p1")))
    }

    @Test func cmdWClosesTheSelectedTabsButKeepsPinnedOnes() {
        let strip = model()
        click(strip, "p1", .toggle)
        click(strip, "t3", .toggle)
        #expect(strip.keyboardCloseSelection("t3", closesPinned: false) == ids("t2", "t3"))
        #expect(strip.keyboardCloseSelection("t3", closesPinned: true) == ids("p1", "t2", "t3"))
        // Without a selection (or a selection of pinned tabs only) the one-tab rule applies.
        let single = model()
        #expect(single.keyboardCloseSelection("t2", closesPinned: false) == nil)
        let pinned = model(active: "p0")
        click(pinned, "p1", .toggle)
        #expect(pinned.keyboardCloseSelection("p1", closesPinned: false) == nil)
    }

    // MARK: Moving the selection

    /// Chrome's own example (`TabStripModel::MoveSelectedTabsTo`): [A b c D E f] moved to 1 is [b A D E c f].
    @Test func aMoveGathersTheSelectionInOrderAtTheIndex() {
        let move = TabSelectionMove(order: ids("A", "b", "c", "D", "E", "f"), pinned: [])
        #expect(move.moving(Set(ids("A", "D", "E")), to: 1) == ids("b", "A", "D", "E", "c", "f"))
        #expect(move.moving(Set(ids("A", "D", "E")), to: 3) == ids("b", "c", "f", "A", "D", "E"))
    }

    @Test func aMoveKeepsPinnedAndUnpinnedTabsInTheirSections() {
        // p0 P1 pinned (P1 selected), t2 T3 t4 T5 (T3, T5 selected).
        let move = TabSelectionMove(order: ids("p0", "P1", "t2", "T3", "t4", "T5"), pinned: Set(ids("p0", "P1")))
        let selection = Set(ids("P1", "T3", "T5"))
        // Past the pinned tabs: the pinned one goes to their end, the rest to the index.
        #expect(move.moving(selection, to: 3) == ids("p0", "P1", "t2", "t4", "T3", "T5"))
        // Among the pinned tabs: the unpinned ones go to the start of the rest.
        #expect(move.moving(selection, to: 0) == ids("P1", "p0", "T3", "T5", "t2", "t4"))
    }

    @Test func oneTabMovesAtATimeReachTheDroppedOrder() {
        let start = ids("p0", "p1", "t2", "t3", "t4", "t5", "t6")
        let target = ids("p1", "p0", "t4", "t2", "t6", "t3", "t5")
        var current = start
        var steps = 0
        while let step = TabSelectionMove.nextStep(from: current, toward: target) {
            current.removeAll { $0 == step.id }
            current.insert(step.id, at: step.index)
            steps += 1
            #expect(steps <= start.count, "the moves do not converge")
            if steps > start.count { break }
        }
        #expect(current == target)
    }

    @Test func theLocalReducerAppliesAMultiTabReorder() {
        let strip = model()
        let order = ids("p0", "p1", "t3", "t2", "t5", "t4")
        #expect(strip.apply(.reorderTabs(order)) { TabItem(id: "new", title: "") })
        #expect(strip.orderedTabs.map(\.id) == order)
        // An order that does not name every tab is refused.
        #expect(!strip.apply(.reorderTabs(ids("t2"))) { TabItem(id: "new", title: "") })
    }
}
