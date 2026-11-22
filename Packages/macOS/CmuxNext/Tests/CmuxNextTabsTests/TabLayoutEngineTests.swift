import CoreGraphics
import Testing
@testable import CmuxNextTabs

private func items(_ count: Int, pinned: Int = 0, selected: Int? = nil) -> [TabLayoutItem] {
    (0..<count).map { TabLayoutItem(id: TabID("t\($0)"), isPinned: $0 < pinned, isSelected: $0 == selected) }
}

/// Fixed numbers so the layout math is tested independently of design tokens.
let m: TabStripMetrics = {
    var m = TabStripMetrics()
    m.maxTabWidth = 240
    m.minInactiveTabWidth = 40
    m.minActiveTabWidth = 56
    m.pinnedTabWidth = 40
    m.compactTabWidth = 160
    m.pinnedGroupGap = 6
    m.closeMinContentsWidth = 68
    m.titleMinVisibleWidth = 12
    m.iconTitleSpacing = 6
    m.contentLeadingInset = 10
    m.contentTrailingInset = 6
    m.iconSize = 16
    m.closeButtonSize = 18
    m.titleCloseSpacing = 4
    return m
}()

@Suite("Overflow")
struct OverflowTests {
    @Test func tabsStopAtMinimumAndOverflow() {
        let result = TabLayoutEngine.layout(items: items(40, selected: 0), availableWidth: 800, style: .chrome, metrics: m)
        #expect(result.slots[0].width == m.minActiveTabWidth)
        #expect(result.slots[1...].allSatisfy { $0.width == m.minInactiveTabWidth })
        #expect(result.isOverflowing)
        #expect(result.contentWidth == m.minActiveTabWidth + 39 * m.minInactiveTabWidth)
    }

    @Test func compactOverflowsWithoutShrinking() {
        let result = TabLayoutEngine.layout(items: items(10), availableWidth: 600, style: .compact, metrics: m)
        #expect(result.isOverflowing)
        #expect(result.contentWidth == 10 * m.compactTabWidth)
    }

    @Test func scrollClamps() {
        #expect(TabScrollMath.clamp(-10, contentWidth: 1000, viewportWidth: 400) == 0)
        #expect(TabScrollMath.clamp(900, contentWidth: 1000, viewportWidth: 400) == 600)
        #expect(TabScrollMath.clamp(50, contentWidth: 300, viewportWidth: 400) == 0)
    }

    @Test func revealScrollsMinimallyWithFadeMargin() {
        let slot = TabLayoutSlot(id: "x", x: 700, width: 40, isPinned: false)
        let offset = TabScrollMath.offset(revealing: slot, current: 0, contentWidth: 1000, viewportWidth: 400, margin: 24)
        #expect(offset == 364) // trailing edge 740 plus the 24pt fade, minus the 400pt viewport
        let back = TabScrollMath.offset(
            revealing: TabLayoutSlot(id: "y", x: 100, width: 40, isPinned: false),
            current: offset, contentWidth: 1000, viewportWidth: 400, margin: 24
        )
        #expect(back == 76)
        let visible = TabScrollMath.offset(
            revealing: TabLayoutSlot(id: "z", x: 500, width: 40, isPinned: false),
            current: 364, contentWidth: 1000, viewportWidth: 400, margin: 24
        )
        #expect(visible == 364)
    }

    @Test func revealFirstAndLastTabsReachTheEdges() {
        let first = TabScrollMath.offset(revealing: TabLayoutSlot(id: "a", x: 0, width: 40, isPinned: false), current: 300, contentWidth: 1000, viewportWidth: 400, margin: 24)
        #expect(first == 0)
        let last = TabScrollMath.offset(revealing: TabLayoutSlot(id: "b", x: 960, width: 40, isPinned: false), current: 0, contentWidth: 1000, viewportWidth: 400, margin: 24)
        #expect(last == 600)
    }

    @Test func fadedEdges() {
        #expect(TabScrollMath.fadedEdges(offset: 0, contentWidth: 1000, viewportWidth: 400) == (false, true))
        #expect(TabScrollMath.fadedEdges(offset: 300, contentWidth: 1000, viewportWidth: 400) == (true, true))
        #expect(TabScrollMath.fadedEdges(offset: 600, contentWidth: 1000, viewportWidth: 400) == (true, false))
        #expect(TabScrollMath.fadedEdges(offset: 0, contentWidth: 300, viewportWidth: 400) == (false, false))
        // Half a point of slack, and a rubber band past either end, show no fade there.
        #expect(TabScrollMath.fadedEdges(offset: 0.5, contentWidth: 1000, viewportWidth: 400) == (false, true))
        #expect(TabScrollMath.fadedEdges(offset: 599.5, contentWidth: 1000, viewportWidth: 400) == (true, false))
        #expect(TabScrollMath.fadedEdges(offset: -30, contentWidth: 1000, viewportWidth: 400) == (false, true))
        #expect(TabScrollMath.fadedEdges(offset: 640, contentWidth: 1000, viewportWidth: 400) == (true, false))
        #expect(TabScrollMath.fadedEdges(offset: -30, contentWidth: 300, viewportWidth: 400) == (false, false))
    }
}

