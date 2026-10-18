@testable import CmuxNextApp
import Testing

/// Leo 2026-10-18 (NEXT nightly): closing the bottom workspace selected the top one instead of
/// the row above it. The window registry lists members in the order they joined; the sidebar
/// shows them in its sections' order. The close walked the registry's order, so "the next row"
/// was whatever joined after it.
struct WindowCloseNeighborTests {
    // Joined c, then a, then b; the sidebar shows a, b, c (c at the bottom).
    private let joined = ["c", "a", "b"]
    private let rows = ["a", "b", "c"]

    @Test func closingTheBottomRowSelectsTheRowAboveIt() {
        let old = WindowRegistry.sidebarOrdered(joined, rows: rows, current: "c")
        let pick = WindowRegistry.repairedSelection(current: "c", previous: old, members: ["a", "b"])
        #expect(pick == "b")
    }

    @Test func closingAMiddleRowSelectsTheRowBelowIt() {
        let old = WindowRegistry.sidebarOrdered(joined, rows: rows, current: "b")
        let pick = WindowRegistry.repairedSelection(current: "b", previous: old, members: ["c", "a"])
        #expect(pick == "c")
    }

    @Test func aSelectionTheSidebarNoLongerListsKeepsTheRegistryOrder() {
        #expect(WindowRegistry.sidebarOrdered(joined, rows: ["a", "b"], current: "c") == joined)
    }

    @Test func membersTheSidebarDoesNotListStayAtTheEnd() {
        #expect(WindowRegistry.sidebarOrdered(["x", "c", "a", "b"], rows: rows, current: "c") == ["a", "b", "c", "x"])
    }
}
