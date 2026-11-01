import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Tab Overflow (cx-kp9b4) on a real strip in a window: crowded Shrink tabs stop at a minimum that keeps
/// part of the title and then scroll; Scroll keeps tabs about 140 wide and scrolls; a crowded strip
/// scrolls with no banner, and wheel, trackpad and selection move it.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabStripOverflowTests {
    private struct Harness {
        let window: NSWindow
        let strip: TabStripView
        let selected: TabID

        init(count: Int, width: CGFloat = 1600) {
            let tabs = (0..<count).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }
            selected = TabID("tab\(count - 1)")
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: selected))
            strip.dragsWindowFromEmptySpace = false
            strip.frame = NSRect(x: 0, y: 0, width: width, height: TabStripView.preferredHeight)
            window.contentView = strip
            settle()
        }

        func settle() {
            strip.layoutSubtreeIfNeeded()
            strip.layoutSubtreeIfNeeded()
        }

        var unselectedWidths: [CGFloat] { strip.result.slots.filter { $0.id != selected }.map(\.width) }
    }

    @Test func shrinkingTabsStopAtChromesMinimumThenScroll() throws {
        DesignSettings.shared.tabOverflow = .shrink
        let harness = Harness(count: 60)
        defer { harness.window.closeAfterTest() }
        let metrics = harness.strip.metrics
        // Room for the favicon and the x (Lawrence 2026-10-20, was Chrome's 32) inactive, Chrome's 56 selected.
        #expect(metrics.minInactiveTabWidth == metrics.faviconCloseWidth && metrics.minActiveTabWidth == 56,
                "\(metrics.minInactiveTabWidth) / \(metrics.minActiveTabWidth)")
        #expect(metrics.minActiveTabWidth >= metrics.minInactiveTabWidth)
        #expect(harness.unselectedWidths.allSatisfy { $0 == metrics.minInactiveTabWidth }, "\(Set(harness.unselectedWidths))")
        // The selected tab is as wide as the others: a selection never moves a tab (2026-10-19).
        let selected = try #require(harness.strip.result.slot(harness.selected))
        #expect(selected.width == metrics.minInactiveTabWidth)
        #expect(harness.strip.result.contentWidth > harness.strip.viewportWidth, "60 tabs at the minimum fit, nothing scrolls")
        let cell = try #require(harness.strip.cells[harness.selected])
        #expect(cell.frame.maxX <= harness.strip.tabsClip.bounds.maxX + 0.5, "the selected last tab is scrolled out of view")
    }

    @Test func scrollingTabsKeepAComfortableWidthAndScroll() throws {
        DesignSettings.shared.tabOverflow = .scroll
        defer { DesignSettings.shared.tabOverflow = .shrink }
        let harness = Harness(count: 20)
        defer { harness.window.closeAfterTest() }
        harness.strip.applyTokens(animated: false)
        harness.settle()
        let metrics = harness.strip.metrics
        #expect(metrics.overflow == .scroll)
        #expect(metrics.minInactiveTabWidth >= 140)
        #expect(harness.unselectedWidths.allSatisfy { $0 >= 140 }, "\(Set(harness.unselectedWidths))")
        #expect(harness.strip.result.contentWidth > harness.strip.viewportWidth, "20 tabs at 140 pt fit in 1600 pt")
        let cell = try #require(harness.strip.cells[harness.selected])
        let viewport = harness.strip.tabsClip.bounds
        #expect(cell.frame.minX >= viewport.minX - 0.5 && cell.frame.maxX <= viewport.maxX + 0.5,
                "the selected tab is at \(cell.frame.minX)...\(cell.frame.maxX), the strip shows 0...\(viewport.width)")
    }

    /// The selected tab's slot lies inside the tabs' viewport at the strip's scroll offset.
    private func isInView(_ id: TabID, _ strip: TabStripView) -> Bool {
        guard let slot = strip.result.slot(id) else { return false }
        let minX = slot.x - strip.scrollOffset, maxX = slot.x + slot.width - strip.scrollOffset
        return minX >= -0.5 && maxX <= strip.viewportWidth + 0.5
    }

    /// A wheel or trackpad scroll over the strip.
    private func wheel(_ strip: TabStripView, dy: Int32 = 0, dx: Int32 = 0, units: CGScrollEventUnit) throws {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
        strip.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
    }

    /// Leo 2026-10-19: tabs at their minimum width put a banner ("Tabs are at their minimum width. Use
    /// scrolling tabs?") and an x on the strip. A crowded strip now just scrolls, Chrome/Arc/Zen style:
    /// the selected tab stays in view, the hidden side fades, and nothing but tabs and + is in the strip.
    @Test func aCrowdedStripScrollsWithNoBanner() throws {
        DesignSettings.shared.tabOverflow = .shrink
        // The tab strip of an 1100 pt window.
        let harness = Harness(count: 40, width: 854)
        defer { harness.window.closeAfterTest() }
        let strip = harness.strip
        try #require(strip.result.isOverflowing, "40 tabs fit in 854 pt, nothing scrolls")
        #expect(isInView(harness.selected, strip), "the selected last tab is scrolled out of view")
        #expect(strip.edgeFade.edges.leading && !strip.edgeFade.edges.trailing, "\(strip.edgeFade.edges)")

        // No banner: the tabs' viewport runs up to the +, and the strip holds no label or button of its own.
        let metrics = strip.metrics
        let plusX = strip.bounds.width - metrics.stripHorizontalPadding - metrics.newTabButtonWidth
        #expect(abs(strip.tabsClip.frame.maxX - plusX) <= 0.5, "something takes \(plusX - strip.tabsClip.frame.maxX) pt beside the tabs")
        func controls(in view: NSView) -> [NSView] {
            view.subviews.flatMap { ($0 is NSButton || $0 is NSTextField ? [$0] : []) + controls(in: $0) }
        }
        let stray = controls(in: strip).filter { $0.isHiddenOrHasHiddenAncestor == false && !$0.isDescendant(of: strip.newTabButton) }
        #expect(stray.isEmpty, "the strip shows \(stray)")
        let extra = (strip.accessibilityChildren() ?? []).filter { child in
            !(child as AnyObject === strip.newTabButton) && !strip.cells.values.contains { $0.accessibility === child as AnyObject }
                && !strip.groups.chips.values.contains { $0.accessibility === child as AnyObject }
        }
        #expect(extra.isEmpty, "VoiceOver finds \(extra) in the strip")
    }

    @Test func wheelAndTrackpadScrollACrowdedStripAndSelectionScrollsBack() throws {
        DesignSettings.shared.tabOverflow = .shrink
        let harness = Harness(count: 40, width: 854)
        defer { harness.window.closeAfterTest() }
        let strip = harness.strip
        try #require(strip.result.isOverflowing)
        let end = strip.scrollOffset
        try #require(end > 0, "the selected last tab did not scroll the strip")

        // A mouse wheel (vertical, line steps) scrolls the strip sideways.
        try wheel(strip, dy: 3, units: .line)
        #expect(strip.scrollOffset < end, "a vertical wheel left the strip at \(strip.scrollOffset)")
        let afterWheel = strip.scrollOffset
        // A trackpad's horizontal swipe scrolls it too, down to the start.
        try wheel(strip, dx: 100_000, units: .pixel)
        #expect(strip.scrollOffset < afterWheel)
        #expect(strip.scrollOffset == 0, "the strip stopped at \(strip.scrollOffset), not its start")
        #expect(!strip.edgeFade.edges.leading && strip.edgeFade.edges.trailing, "\(strip.edgeFade.edges)")
        #expect(!isInView(harness.selected, strip))

        // Selecting the scrolled-away tab brings it back into view.
        strip.model.selectedID = TabID("tab0")
        strip.syncFromModel()
        strip.model.selectedID = harness.selected
        strip.syncFromModel()
        #expect(isInView(harness.selected, strip), "the selected tab stays scrolled away")
    }
}
