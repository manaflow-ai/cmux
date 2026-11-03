import AppKit
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// A New Tab page's tab takes no hover card: the card would repeat its title over an empty
/// frame (Leo 2026-10-11). Other tabs keep theirs.
@MainActor
@Suite(.closesItsWindows)
struct TabHoverCardNewTabTests {
    @Test func aNewTabPageTakesNoHoverCard() throws {
        var newTab = TabItem(id: TabID("new"), title: "New Tab")
        newTab.isNewTabPage = true
        let page = TabItem(id: TabID("page"), title: "cmux", subtitle: "https://cmux.com")
        let model = TabStripModel(tabs: [newTab, page], selectedID: TabID("page"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let strip = TabStripView(model: model)
        strip.frame = NSRect(x: 0, y: 0, width: 600, height: TabStripView.preferredHeight)
        window.contentView = strip
        strip.layoutSubtreeIfNeeded()
        func center(_ id: TabID) throws -> CGPoint {
            let cell = try #require(strip.cells[id])
            return strip.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), from: strip.tabsClip)
        }
        #expect(strip.hoverCard.target(at: try center(TabID("page")))?.id == TabID("page"))
        #expect(strip.hoverCard.target(at: try center(TabID("new"))) == nil)
    }
}
