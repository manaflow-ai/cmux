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

@Suite("Width distribution")
struct WidthDistributionTests {
    @Test func fewTabsGetMaxWidth() {
        let result = TabLayoutEngine.layout(items: items(3), availableWidth: 1200, style: .chrome, metrics: m)
        #expect(result.slots.map(\.width) == [240, 240, 240])
        #expect(result.slots.map(\.x) == [0, 240, 480])
        #expect(result.contentWidth == 720)
        #expect(!result.isOverflowing)
    }

    @Test func tabsShrinkEvenlyToFill() {
        let result = TabLayoutEngine.layout(items: items(8), availableWidth: 1000, style: .chrome, metrics: m)
        #expect(result.slots.allSatisfy { $0.width == 125 })
        #expect(result.contentWidth == 1000)
    }

    @Test func leftoverPointsGoToLeadingTabs() {
        let result = TabLayoutEngine.layout(items: items(3), availableWidth: 302, style: .chrome, metrics: m)
        #expect(result.slots.map(\.width) == [101, 101, 100])
        #expect(result.contentWidth == 302)
    }

    @Test func slotsAreContiguous() {
        let result = TabLayoutEngine.layout(items: items(13), availableWidth: 917, style: .chrome, metrics: m)
        for (a, b) in zip(result.slots, result.slots.dropFirst()) {
            #expect(a.maxX == b.x)
        }
    }

    @Test func selectedTabKeepsMinimumWhenOthersShrinkBelowIt() {
        // 20 tabs in 900pt: ideal 45 < minActive 56.
        let result = TabLayoutEngine.layout(items: items(20, selected: 5), availableWidth: 900, style: .chrome, metrics: m)
        #expect(result.slots[5].width == m.minActiveTabWidth)
        let others = result.slots.enumerated().filter { $0.offset != 5 }.map(\.element.width)
        #expect(others.allSatisfy { $0 >= m.minInactiveTabWidth && $0 < m.minActiveTabWidth })
        #expect(result.contentWidth <= 900)
        #expect(result.contentWidth > 899)
    }

    @Test func pinnedTabsAreFixedWidthWithGroupGap() {
        let result = TabLayoutEngine.layout(items: items(5, pinned: 2), availableWidth: 2000, style: .chrome, metrics: m)
        #expect(result.slots[0].width == m.pinnedTabWidth)
        #expect(result.slots[1].width == m.pinnedTabWidth)
        #expect(result.slots[2].x == 2 * m.pinnedTabWidth + m.pinnedGroupGap)
        #expect(result.slots[2].width == 240)
    }

    @Test func pinnedWidthIsTakenBeforeDistributing() {
        let available: CGFloat = 1000
        let result = TabLayoutEngine.layout(items: items(10, pinned: 2), availableWidth: available, style: .chrome, metrics: m)
        let unpinnedTotal = available - 2 * m.pinnedTabWidth - m.pinnedGroupGap
        #expect(result.slots[2...].map(\.width).reduce(0, +) == unpinnedTotal.rounded(.down))
        #expect(result.contentWidth <= available)
    }

    @Test func onlyPinnedTabsHaveNoGap() {
        let result = TabLayoutEngine.layout(items: items(3, pinned: 3), availableWidth: 500, style: .chrome, metrics: m)
        #expect(result.contentWidth == 3 * m.pinnedTabWidth)
        #expect(result.standardWidth == 0)
    }

    @Test func compactStyleUsesFixedWidth() {
        let result = TabLayoutEngine.layout(items: items(4, pinned: 1), availableWidth: 2000, style: .compact, metrics: m)
        #expect(result.slots[0].width == m.pinnedTabWidth)
        #expect(result.slots[1...].allSatisfy { $0.width == m.compactTabWidth })
    }

    @Test func emptyStrip() {
        let result = TabLayoutEngine.layout(items: [], availableWidth: 500, style: .chrome, metrics: m)
        #expect(result.slots.isEmpty)
        #expect(result.contentWidth == 0)
    }

    @Test func distributeNeverExceedsTotal() {
        for total in stride(from: CGFloat(0), through: 400, by: 7.3) {
            for count in 1...9 {
                let widths = TabLayoutEngine.distribute(total, count: count)
                #expect(widths.reduce(0, +) <= total)
                #expect(total - widths.reduce(0, +) < 1)
                #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 1)
            }
        }
    }
}

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

@Suite("Deferred relayout (closing mode)")
struct ClosingModeTests {
    private func layout(_ ids: [TabID], selected: TabID? = nil, available: CGFloat, closing: CGFloat?) -> TabLayoutResult {
        TabLayoutEngine.layout(
            items: ids.map { TabLayoutItem(id: $0, isSelected: $0 == selected) },
            availableWidth: available,
            style: .chrome,
            metrics: m,
            closingModeWidth: closing
        )
    }

    @Test func closingMiddleTabKeepsWidthsSoNextCloseButtonSlidesUnderPointer() {
        let ids = (0..<10).map { TabID("t\($0)") }
        let before = layout(ids, available: 1000, closing: nil)
        #expect(before.slots.allSatisfy { $0.width == 100 })

        let closing = TabLayoutEngine.closingModeWidth(afterClosing: "t3", in: before, current: nil)
        #expect(closing == 900)

        var remaining = ids
        remaining.remove(at: 3)
        let after = layout(remaining, available: 1000, closing: closing)
        #expect(after.slots.allSatisfy { $0.width == 100 })
        // The tab that was right of the closed one now occupies its slot.
        #expect(after.slot("t4")?.x == before.slot("t3")?.x)
        #expect(after.slot("t4")?.maxX == before.slot("t3")?.maxX)

        // Without closing mode the tabs would grow and move the close button.
        let unfrozen = layout(remaining, available: 1000, closing: nil)
        #expect(unfrozen.slots[0].width > 100)
    }

    @Test func repeatedClosesStayFrozen() {
        var ids = (0..<10).map { TabID("t\($0)") }
        var current: CGFloat?
        var result = layout(ids, available: 1000, closing: nil)
        for _ in 0..<4 {
            current = TabLayoutEngine.closingModeWidth(afterClosing: ids[2], in: result, current: current)
            ids.remove(at: 2)
            result = layout(ids, available: 1000, closing: current)
            #expect(result.slots.allSatisfy { $0.width == 100 })
        }
        #expect(current == 600)
    }

    @Test func closingLastTabLetsTabsGrowBack() {
        let ids = (0..<10).map { TabID("t\($0)") }
        let before = layout(ids, available: 1000, closing: nil)
        let closing = TabLayoutEngine.closingModeWidth(afterClosing: "t9", in: before, current: nil)
        #expect(closing == nil)
        let after = layout(Array(ids.dropLast()), available: 1000, closing: closing)
        #expect(after.slots.last?.maxX == 1000)
    }

    @Test func closingModeNeverWidensBeyondTheRealStrip() {
        let ids = (0..<4).map { TabID("t\($0)") }
        let result = layout(ids, available: 300, closing: 5000)
        #expect(result.contentWidth <= 300)
    }

    @Test func closingOnlyPinnedTabRemovesGroupGap() {
        let items = [TabLayoutItem(id: "p", isPinned: true)] + (0..<5).map { TabLayoutItem(id: TabID("t\($0)")) }
        let before = TabLayoutEngine.layout(items: items, availableWidth: 600, style: .chrome, metrics: m)
        let closing = TabLayoutEngine.closingModeWidth(afterClosing: "p", in: before, current: nil)
        let after = TabLayoutEngine.layout(items: Array(items.dropFirst()), availableWidth: 600, style: .chrome, metrics: m, closingModeWidth: closing)
        #expect(zip(before.slots.dropFirst(), after.slots).allSatisfy { $0.width == $1.width })
        #expect(after.slots.first?.x == 0)
    }

    @Test func closingWithOneTabLeftIsNoop() {
        let result = layout(["a"], available: 500, closing: nil)
        #expect(TabLayoutEngine.closingModeWidth(afterClosing: "a", in: result, current: nil) == nil)
    }
}
