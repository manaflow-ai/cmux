import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// A tab's hover card lines up with the tab the user sees: its anchor is the tab's pill, not its
/// layout slot, whose trailing part is the gap to the next tab (Lawrence 2026-10-20: "Tab cards
/// are still disjoint from the tab itself").
@MainActor
@Suite(.closesItsWindows)
struct TabHoverCardAnchorTests {
    @Test func aTabsCardAnchorIsItsDrawnPill() throws {
        let tabs = [TabItem(id: TabID("a"), title: "GitHub"), TabItem(id: TabID("b"), title: "cmux")]
        let model = TabStripModel(tabs: tabs, selectedID: TabID("a"))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let strip = TabStripView(model: model)
        strip.frame = NSRect(x: 0, y: 0, width: 600, height: TabStripView.preferredHeight)
        window.contentView = strip
        strip.layoutSubtreeIfNeeded()
        let cell = try #require(strip.cells[TabID("b")])
        let pill = window.convertToScreen(strip.tabsClip.convert(
            CGRect(x: cell.frame.minX + cell.pillFrameInCell.minX, y: cell.frame.minY,
                   width: cell.pillFrameInCell.width, height: cell.frame.height), to: nil))
        let anchor = try #require(strip.hoverCard.anchor(forTab: TabID("b")))
        #expect(abs(anchor.minX - pill.minX) < 0.01, "anchor leading \(anchor.minX), pill \(pill.minX)")
        #expect(abs(anchor.maxX - pill.maxX) < 0.01, "anchor trailing \(anchor.maxX), pill \(pill.maxX)")
        #expect(abs(anchor.minY - pill.minY) < 0.01 && abs(anchor.maxY - pill.maxY) < 0.01)
        #expect(cell.pillFrameInCell.width < cell.frame.width, "the slot holds the gap after the pill")
    }
}
