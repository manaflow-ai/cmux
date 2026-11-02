import AppKit
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// A pane split to 280, 360 or 480 pt narrows its tab strip without a new selection: the strip
/// relayouts, the tabs overflow and scroll, and the selected tab must stay in view. It scrolled
/// off the trailing edge instead, so after a split the pane showed no selected tab at all.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabStripNarrowPaneTests {
    @Test(arguments: [(10, 280.0), (20, 280.0), (20, 360.0), (20, 480.0)])
    func theSelectedTabStaysInViewWhenThePaneNarrows(count: Int, width: Double) throws {
        let tabs = (0..<count).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }
        let selected = TabID("tab\(count - 1)")
        let model = TabStripModel(tabs: tabs, selectedID: selected)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        strip.frame = NSRect(x: 0, y: 0, width: 1600, height: TabStripView.preferredHeight)
        window.contentView = strip
        strip.layoutSubtreeIfNeeded()
        try #require(strip.result.contentWidth <= strip.viewportWidth, "the tabs already overflow before the split")

        // The split: the pane, and its strip, narrow; nothing else changes.
        strip.setFrameSize(NSSize(width: width, height: strip.frame.height))
        strip.layoutSubtreeIfNeeded()
        try #require(strip.result.contentWidth > strip.viewportWidth, "the tabs fit at \(width) pt, nothing to scroll")

        let cell = try #require(strip.cells[selected])
        let viewport = strip.tabsClip.bounds
        #expect(cell.frame.minX >= viewport.minX && cell.frame.maxX <= viewport.maxX,
                "the selected tab is at \(cell.frame.minX)...\(cell.frame.maxX), the strip shows 0...\(viewport.width)")
    }
}
