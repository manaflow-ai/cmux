import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Pinned tabs stay fixed at the strip's leading edge while an overflowing strip scrolls (cx-kp9b4,
/// Safari/Arc): only the unpinned tabs scroll, under and after them, in both Tab Overflow modes. A
/// scrolled strip moved its pinned tabs off the leading edge with the rest, so a click there hit
/// an unpinned tab or nothing.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabStripPinnedScrollTests {
    private struct Harness {
        let window: NSWindow
        let strip: TabStripView
        let pinned: [TabID]
        let last: TabID

        init(pinned pinnedCount: Int, unpinned: Int, width: CGFloat) {
            let tabs = (0..<(pinnedCount + unpinned)).map {
                TabItem(id: TabID("tab\($0)"), title: "Tab \($0)", isPinned: $0 < pinnedCount)
            }
            pinned = tabs.prefix(pinnedCount).map(\.id)
            last = tabs[tabs.count - 1].id
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: last))
            strip.dragsWindowFromEmptySpace = false
            strip.frame = NSRect(x: 0, y: 0, width: width, height: TabStripView.preferredHeight)
            window.contentView = strip
            strip.layoutSubtreeIfNeeded()
            strip.layoutSubtreeIfNeeded()
        }

        /// The pinned tabs and their gap: where the first unpinned slot starts.
        var band: CGFloat { strip.result.slots.first { !$0.isPinned }?.x ?? 0 }

        func scroll(to id: TabID) {
            strip.reveal(id, animated: false)
            strip.applyFrames()
        }

        /// The part of `id`'s cell that draws, in the clip: its bounds cut to its mask and to every
        /// clipping layer it sits in.
        func visibleSpan(_ id: TabID) -> ClosedRange<CGFloat>? {
            guard let cell = strip.cells[id], let clip = strip.tabsClip.layer else { return nil }
            var visible = cell.layer.convert(cell.layer.mask?.frame ?? cell.layer.bounds, to: clip)
            var ancestor = cell.layer.superlayer
            while let layer = ancestor, layer !== clip {
                if layer.masksToBounds { visible = visible.intersection(layer.convert(layer.bounds, to: clip)) }
                ancestor = layer.superlayer
            }
            guard !visible.isNull, visible.width > 0.5 else { return nil }
            return visible.minX...visible.maxX
        }

        func hit(_ id: TabID) throws -> TabID? {
            let cell = try #require(strip.cells[id])
            return strip.tabID(at: strip.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), from: strip.tabsClip))
        }
    }

    @Test(arguments: [TabOverflow.shrink, .scroll])
    func pinnedTabsStayAtTheLeadingEdgeWhileTheStripScrolls(overflow: TabOverflow) throws {
        DesignSettings.shared.tabOverflow = overflow
        defer { DesignSettings.shared.tabOverflow = .shrink }
        let harness = Harness(pinned: 2, unpinned: 40, width: 1000)
        defer { harness.window.closeAfterTest() }
        harness.strip.applyTokens(animated: false)
        harness.strip.layoutSubtreeIfNeeded()
        let strip = harness.strip
        try #require(strip.result.contentWidth > strip.viewportWidth, "42 tabs fit in 1000 pt, nothing scrolls")

        harness.scroll(to: harness.last)
        try #require(strip.scrollOffset > 0, "revealing the last tab did not scroll the strip")
        for id in harness.pinned {
            let slot = try #require(strip.result.slot(id))
            let cell = try #require(strip.cells[id])
            #expect(abs(cell.frame.minX - slot.x) <= 0.5, "pinned \(id.rawValue) is at \(cell.frame.minX), its slot at \(slot.x)")
            #expect(cell.frame.width == strip.metrics.pinnedTabWidth)
            #expect(try harness.hit(id) == id, "a click on scrolled pinned \(id.rawValue) hit another tab")
        }
        // The unpinned tabs scrolled.
        let unpinned = try #require(strip.result.slots.last { !$0.isPinned })
        let lastCell = try #require(strip.cells[unpinned.id])
        #expect(abs(lastCell.frame.minX - (unpinned.x - strip.scrollOffset)) <= 0.5)
        #expect(lastCell.frame.maxX <= strip.viewportWidth + 0.5, "the selected last tab is out of view")
        // Unpinned tabs scrolled under the pinned band draw nothing over it.
        let band = harness.band
        for slot in strip.result.slots where !slot.isPinned {
            guard let span = harness.visibleSpan(slot.id) else { continue }
            #expect(span.upperBound <= span.lowerBound + 0.5 || span.lowerBound >= band - 0.5,
                    "unpinned \(slot.id.rawValue) draws at \(span) over the pinned tabs (band \(band))")
        }

        // Revealing the first unpinned tab scrolls it out from under the pinned tabs, to the band's edge.
        let first = try #require(strip.result.slots.first { !$0.isPinned })
        harness.scroll(to: first.id)
        let firstCell = try #require(strip.cells[first.id])
        #expect(abs(firstCell.frame.minX - band) <= 0.5, "the first unpinned tab is at \(firstCell.frame.minX), the band ends at \(band)")

        // A pinned tab is always in view: revealing it scrolls nothing.
        harness.scroll(to: harness.last)
        let scrolled = strip.scrollOffset
        harness.scroll(to: harness.pinned[0])
        #expect(strip.scrollOffset == scrolled, "revealing a pinned tab scrolled the strip from \(scrolled) to \(strip.scrollOffset)")
    }

    /// Pinned tabs wider than the strip cannot stay fixed: the whole strip scrolls, pinned tabs too.
    /// The strip is narrower than its pinned tabs at today's pinned width (a setting: 64 pt until
    /// ebadb28722f, 36 pt since), so the case holds whatever the width is.
    @Test func pinnedTabsWiderThanTheStripScrollWithTheRest() throws {
        DesignSettings.shared.tabOverflow = .shrink
        let pinnedCount = 12
        let width = (CGFloat(pinnedCount) * Metrics.tabPinnedWidth * 0.8).rounded()
        let harness = Harness(pinned: pinnedCount, unpinned: 6, width: width)
        defer { harness.window.closeAfterTest() }
        let strip = harness.strip
        try #require(CGFloat(pinnedCount) * strip.metrics.pinnedTabWidth > strip.viewportWidth,
                     "\(pinnedCount) pinned tabs of \(strip.metrics.pinnedTabWidth) pt fit in \(strip.viewportWidth) pt")
        harness.scroll(to: harness.last)
        try #require(strip.scrollOffset > 0)
        let cell = try #require(strip.cells[harness.pinned[0]])
        #expect(cell.frame.minX < -0.5, "\(pinnedCount) pinned tabs in \(width) pt stayed fixed, the unpinned tabs have no room")
        let lastCell = try #require(strip.cells[harness.last])
        #expect(lastCell.frame.maxX <= strip.viewportWidth + 0.5)
    }
}
