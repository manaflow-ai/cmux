import CmuxNextBridge
import CmuxNextBridgeUI
@testable import CmuxNextApp
import CmuxNextLayout
import Foundation
import Testing

/// A link dragged out of a Home chat (or in from another app) drops where a dragged tab drops
/// (Lawrence 2026-10-20: "drag a link, like a PR URL, to the right side or anywhere and make a
/// split"): which links drag at all, and what each layout drop zone does with one.
struct LinkDragDropTests {
    @Test func aWebPageAndAnAbsoluteFileDrag() throws {
        let pr = try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/22436"))
        #expect(LinkDragItem(pr, browserEnabled: true) == .web(pr))
        #expect(LinkDragItem(pr, browserEnabled: true)?.title == "github.com/manaflow-ai/cmux/pull/22436")
        let file = URL(fileURLWithPath: "/Users/me/notes/plan.md")
        #expect(LinkDragItem(file, browserEnabled: false) == .file(file))
        #expect(LinkDragItem(file, browserEnabled: false)?.title == "plan.md")
    }

    @Test(arguments: ["mailto:me@example.com", "cmux://workspace/ws_1", "ftp://example.com/a", "https:///nohost"])
    func otherLinksDoNotDrag(_ raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(LinkDragItem(url, browserEnabled: true) == nil)
    }

    @Test func aWebLinkDoesNotDragWhileTheCmuxBrowserIsOff() throws {
        let url = try #require(URL(string: "https://example.com"))
        #expect(LinkDragItem(url, browserEnabled: false) == nil)
    }

    @Test func everyZoneOfATabDropOpensTheLinkThere() {
        let pane = LayoutPaneID("pane_a"), screen = LayoutScreenID("screen_a"), column = LayoutColumnID("col_a")
        let takes: (LayoutPaneID) -> Bool = { _ in true }
        #expect(LinkDropPlan(.pane(pane, .center), takesTabs: takes) == .tab(in: pane))
        #expect(LinkDropPlan(.pane(pane, .right), takesTabs: takes) == .split(pane, edge: .right))
        #expect(LinkDropPlan(.pane(pane, .left), takesTabs: takes) == .split(pane, edge: .left))
        #expect(LinkDropPlan(.pane(pane, .top), takesTabs: takes) == .split(pane, edge: .top))
        #expect(LinkDropPlan(.pane(pane, .bottom), takesTabs: takes) == .split(pane, edge: .bottom))
        #expect(LinkDropPlan(.newColumn(screen: screen, after: column), takesTabs: takes) == .column(screen: screen, after: column))
        #expect(LinkDropPlan(.newDock(screen: screen, edge: .bottom), takesTabs: takes) == .dock(screen: screen, edge: .bottom))
    }

    @Test func thePinnedHomeColumnTakesNoLinkTabButSplits() {
        let home = LayoutPaneID("pane_home")
        let none: (LayoutPaneID) -> Bool = { _ in false }
        #expect(LinkDropPlan(.pane(home, .center), takesTabs: none) == nil)
        #expect(LinkDropPlan(.pane(home, .right), takesTabs: none) == .split(home, edge: .right))
    }
}
