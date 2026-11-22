import Foundation
import Testing
@testable import CmuxMobileModel

/// A tab row dropped on the Panes page (`WorkspaceLayout.dropping`): the tab `move-tab` puts it
/// before, and the layout as the Mac will list it, so the page settles there at once.
@Suite struct PaneTabDropTests {
    /// a, b, c | d, e (the mock ws-panes shape).
    let layout = WorkspaceLayout(screens: [WorkspaceLayout.Screen(id: 1, isActive: true, panes: [
        WorkspaceLayout.Pane(id: 1, tabIDs: ["a", "b", "c"], activeTabID: "c", tabCount: 4),
        WorkspaceLayout.Pane(id: 2, tabIDs: ["d", "e"], activeTabID: "d"),
    ], root: .split(id: 9, axis: .horizontal, ratio: 0.5, first: .pane(1), second: .pane(2)))])

    func tabs(_ l: WorkspaceLayout, _ pane: Int) -> [String] { l.pane(pane)?.tabIDs ?? [] }

    @Test func intoAnotherPaneBeforeARow() throws {
        let drop = try #require(layout.dropping("c", into: 2, at: 1))
        #expect(drop.before == "e")
        #expect(tabs(drop.layout, 1) == ["a", "b"])
        #expect(tabs(drop.layout, 2) == ["d", "c", "e"])
        #expect(drop.layout.pane(1)?.tabCount == 3)
        #expect(drop.layout.pane(2)?.tabCount == 3)
        // The pane it left shows another of its tabs.
        #expect(drop.layout.pane(1)?.activeTabID == "a")
    }

    @Test func intoAnotherPaneAtItsEnd() throws {
        let drop = try #require(layout.dropping("a", into: 2, at: 2))
        #expect(drop.before == nil)
        #expect(tabs(drop.layout, 2) == ["d", "e", "a"])
    }

    @Test func downItsOwnPane() throws {
        // a dropped on c's place (offset 2 counts a's own row): before c.
        let drop = try #require(layout.dropping("a", into: 1, at: 2))
        #expect(drop.before == "c")
        #expect(tabs(drop.layout, 1) == ["b", "a", "c"])
        #expect(drop.layout.pane(1)?.tabCount == 4)
        #expect(drop.layout.pane(1)?.activeTabID == "c")
    }

    @Test func upItsOwnPaneAndToItsEnd() throws {
        #expect(tabs(try #require(layout.dropping("c", into: 1, at: 0)).layout, 1) == ["c", "a", "b"])
        let end = try #require(layout.dropping("a", into: 1, at: 3))
        #expect(end.before == nil)
        #expect(tabs(end.layout, 1) == ["b", "c", "a"])
    }

    @Test func itsOwnPlaceChangesNothing() {
        #expect(layout.dropping("b", into: 1, at: 1) == nil)
        #expect(layout.dropping("b", into: 1, at: 2) == nil)
    }

    @Test func anUnlistedTabOrPaneChangesNothing() {
        #expect(layout.dropping("zz", into: 1, at: 0) == nil)
        #expect(layout.dropping("a", into: 7, at: 0) == nil)
    }

    @Test func anOffsetPastTheRowsIsTheEnd() throws {
        #expect(try #require(layout.dropping("a", into: 2, at: 99)).before == nil)
    }
}
