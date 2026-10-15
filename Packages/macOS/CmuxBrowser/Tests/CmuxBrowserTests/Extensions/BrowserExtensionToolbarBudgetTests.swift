import CoreGraphics
import Testing
@testable import CmuxBrowser

@Suite("Browser extension toolbar budget")
struct BrowserExtensionToolbarBudgetTests {
    @Test
    func wideRowShowsUpToSix() {
        let budget = BrowserExtensionToolbarBudget(rowWidth: 1400, scale: 1, trailingAccessoryCount: 5)
        #expect(budget.visibleCount(pinnedCount: 9) == 6)
        #expect(budget.visibleCount(pinnedCount: 2) == 2)
        #expect(budget.visibleCount(pinnedCount: 0) == 0)
    }

    @Test
    func narrowRowsOverflowFromTheLeftNewestStay() {
        // 16 + 78 + 16 + 200 + 6 = 316 reserved, plus 6 trailing slots (5 accessories + puzzle) of 24 = 460.
        let budget = BrowserExtensionToolbarBudget(rowWidth: 460 + 24 * 2 + 10, scale: 1, trailingAccessoryCount: 5)
        #expect(budget.visibleCount(pinnedCount: 4) == 2)
        let split = budget.split(["old", "mid", "new1", "new2"])
        #expect(split.visible == ["new1", "new2"])
        #expect(split.overflowed == ["old", "mid"])
    }

    @Test
    func tooNarrowShowsNoneAndScaleMatters() {
        #expect(BrowserExtensionToolbarBudget(rowWidth: 300, scale: 1, trailingAccessoryCount: 3).visibleCount(pinnedCount: 3) == 0)
        let wide = BrowserExtensionToolbarBudget(rowWidth: 700, scale: 1, trailingAccessoryCount: 5).visibleCount(pinnedCount: 6)
        let large = BrowserExtensionToolbarBudget(rowWidth: 700, scale: 1.5, trailingAccessoryCount: 5).visibleCount(pinnedCount: 6)
        #expect(large < wide)
    }
}
