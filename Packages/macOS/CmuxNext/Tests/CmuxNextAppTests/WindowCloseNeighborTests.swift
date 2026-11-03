@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextLayout
@testable import CmuxNextSidebar
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
        let pick = WindowRegistry.repairedSelection(current: "c", previous: joined, members: ["a", "b"], orders: [rows])
        #expect(pick == "b")
    }

    @Test func closingAMiddleRowSelectsTheRowBelowIt() {
        let pick = WindowRegistry.repairedSelection(current: "b", previous: joined, members: ["c", "a"], orders: [rows])
        #expect(pick == "c")
    }

    @Test func aSelectionTheSidebarNoLongerListsKeepsTheRegistryOrder() {
        let pick = WindowRegistry.repairedSelection(current: "c", previous: joined, members: ["a", "b"], orders: [["a", "b"]])
        #expect(pick == "a")
    }

    /// The rows are a walk of every workspace; a membership change that keeps the selection (most
    /// of them: any workspace opening, closing or moving elsewhere) must not pay for it.
    @Test func aSelectionThatStaysNeverReadsTheRows() {
        var reads = 0
        func orders() -> [[String]] { reads += 1; return [rows] }
        #expect(WindowRegistry.repairedSelection(current: "a", previous: joined, members: ["a", "b"], orders: orders()) == "a")
        #expect(WindowRegistry.repairedSelection(current: "c", previous: joined, members: ["a", "b"], preferred: ["a"], orders: orders()) == "a")
        #expect(reads == 0)
        #expect(WindowRegistry.repairedSelection(current: "c", previous: joined, members: ["a", "b"], orders: orders()) == "b")
        #expect(reads == 1)
    }

    /// Pinned layout tiles leave the list (SidebarTopProjection): "p" is a member no row lists.
    /// It joined last, so the join order alone would hand the bottom row's close to it.
    @Test func closingTheBottomRowNeverJumpsToAPinnedTile() {
        let pick = WindowRegistry.repairedSelection(current: "c", previous: ["a", "b", "c", "p"], members: ["a", "b", "p"], orders: [rows, rows])
        #expect(pick == "b")
    }

    @Test func aPinnedTileTakesOverWhenNoRowIsLeft() {
        let pick = WindowRegistry.repairedSelection(current: "c", previous: ["p", "c"], members: ["p"], orders: [["c"], ["c"]])
        #expect(pick == "p")
    }

    /// Group by folder sorts the rows as the list draws them; the model and the join order
    /// both put "c" below "b", the drawn rows put "a" there.
    @Test func folderGroupingTakesTheRowBelowAsDrawn() {
        let pick = WindowRegistry.repairedSelection(current: "b", previous: ["a", "b", "c", "d"], members: ["a", "c", "d"],
                                                    orders: [["c", "d", "b", "a"], ["a", "b", "c", "d"]])
        #expect(pick == "a")
    }

    /// A filtered sidebar draws only the rows that match; a hidden row is not the next row.
    @Test func aFilteredSidebarSelectsTheNextShownRow() {
        let pick = WindowRegistry.repairedSelection(current: "a", previous: joined, members: ["b", "c"],
                                                    orders: [["a", "c"], ["a", "b", "c"]])
        #expect(pick == "c")
    }

    /// The sidebar's own close (InstantClose, SidebarModel.dropClosed) follows the drawn rows too.
    @MainActor @Test func theSidebarsCloseFollowsTheDrawnRows() {
        let ids = ["a", "b", "c"].map { CmuxNextSidebar.WorkspaceID($0) }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: ids.map { .workspace(SidebarWorkspace(id: $0, title: $0.rawValue)) })],
                                 activeWorkspaceID: ids[1])
        model.drawnWorkspaceOrder = { [ids[2], ids[0], ids[1]] }
        model.apply(.close([ids[1]]))
        #expect(model.activeWorkspaceID == ids[0])
    }
}
