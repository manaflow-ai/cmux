import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// Row 13. A pane has 12 New Tab tabs that the person did not use, each with a page view of its own, and it shows the
/// last of them. One New Tab key. Want: the new tab has the page view of the tab that the pane showed at the key (the
/// pane's own: it is in that pane, at that pane's size), not the page view of one of the 11 tabs behind it, and no
/// page view is made. The app's record of that open says `idle` and not `spare` (`AgentPaneSpareOpening`): the page
/// is not the pool's.
///
/// The setup makes the 12 page views by the product's own cold path: while each page view that the pane has counts as
/// one that is never given away (`AgentPaneModel.neverPooled`, the mark of a page of another machine), a New Tab key
/// finds no idle page and its tab gets a new page view at its frame. Before the row's key each mark is off again.
///
/// Limit. The store keeps its New Tab page views in a set, and a walk of a set has an order that changes from run
/// to run. A product that takes the first idle page view of that walk passes this row at 1 run of 12.
extension NewTabHoldMovesItsPageTests {
    @Test(arguments: [11]) func aNewTabKeyTakesThePageViewThatItsPaneLeaves(behind: Int) async throws {
        try await Self.row("cn-hold-moves-page-own") { services, pane, views, _ in
            let tabs = services.agentTabs
            for step in 0..<behind {
                for key in Self.newTabs(of: pane, services) { tabs.existingView(key)?.model.neverPooled = true }
                NewTabPage.open(in: pane, seed: nil)
                await NewTabPageAtItsFrameTests.frame(services)
                let shown = try #require(pane.currentTabKey, "setup: the pane shows no tab after New Tab key \(step + 1) of the setup")
                try #require(tabs.existingView(shown) != nil, "setup: the tab of New Tab key \(step + 1) of the setup has no page view at its frame")
            }
            let all = Self.newTabs(of: pane, services)
            for key in all { tabs.existingView(key)?.model.neverPooled = false }
            // The pane's own first New Tab page counts as used (the setup of `row`): it is not one of the row's page views.
            let pages = views.read(pane, services).filter(\.isUntouchedNewTab)
            let own = try #require(pane.currentTabKey.flatMap { tabs.existingView($0) }, "setup: the tab that the pane shows has no page view before the row's key")
            let distinct = pages.enumerated().filter { item in !pages[..<item.offset].contains { $0 === item.element } }.count
            try #require(pages.count == behind + 1 && distinct == behind + 1 && pages.contains { $0 === own }, """
                setup: the pane does not have \(behind + 1) untouched New Tab page views, one for each of its New Tab tabs made by a key, \
                with the shown tab's one among them (tabs with an untouched page view: \(pages.count), distinct page views: \(distinct))
                """)
            let before = views.count
            NewTabPage.open(in: pane, seed: nil)
            let new = try #require(pane.currentTabKey, "setup: the pane shows no tab after the row's New Tab key")
            let took = tabs.existingView(new)
            // The app's record of this open (`debug.new_tab` gives it to the measure scripts): the open's call wrote it last.
            let record = services.newTabSpares.openings.last
            await NewTabPageAtItsFrameTests.frame(services)
            _ = views.read(pane, services)
            let at = pages.firstIndex { $0 === took }.map { String($0 + 1) } ?? "none"
            print("""
                NewTabHoldMovesItsPageTests: row 13, a New Tab key in a pane with \(behind + 1) untouched New Tab page views: at the \
                return of the key's call the new tab has a page view: \(took != nil), the one of the tab that the pane showed at the \
                key: \(took === own), the one of untouched tab \(at) of \(pages.count) in the strip's order; page views made by the \
                key and its frame: \(views.count - before); the app's record of the open says `idle`: \
                \(record.map { String($0.idle) } ?? "no record"), `spare`: \(record.map { String($0.spare) } ?? "no record")
                """)
            #expect(record?.idle == true && record?.spare == false,
                    "the app's record of an open that took an idle page does not say `idle` and not `spare`: a reader that asks for the pool's page (`spare`) must get no for it")
            #expect(took === own, "the new tab did not take the page view of the tab that its pane showed at the key: it has the one of untouched tab \(at) of \(pages.count)")
            #expect(views.count == before, "\(views.count - before) page view(s) made by a New Tab key in a pane with \(behind + 1) untouched page views")
        }
    }
}
