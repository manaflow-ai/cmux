import CoreGraphics
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// Icon-only pinned tabs (`tabs.pinnedKeepsTitle` off) are as thin as Chrome's (about 36 pt), not 64 pt (Lawrence 2026-10-23),
/// at every density; the width stays a setting (`appearance.metrics.tabPinnedWidth`).
@MainActor struct ThinPinnedTabTests {
    @Test(arguments: DensityPreset.allCases)
    func pinnedTabsAreChromeThinAtEveryDensity(preset: DensityPreset) {
        DensityTokens.$scoped.withValue(preset.tokens) {
            var metrics = TabStripMetrics()
            metrics.pinnedKeepsTitle = false // icon-only pinned tabs (`tabs.pinnedKeepsTitle` off)
            #expect(metrics.pinnedTabWidth <= 40, "\(preset.rawValue): pinned tab is \(metrics.pinnedTabWidth) pt wide, Chrome's is 36")
            #expect(metrics.pinnedTabWidth >= metrics.iconSize + 2 * metrics.tabBackgroundInset, "\(preset.rawValue): the icon does not fit")
            let items = (0..<3).map { TabLayoutItem(id: TabID("p\($0)"), isPinned: true) }
            let result = TabLayoutEngine.layout(items: items, availableWidth: 800, style: .chrome, metrics: metrics)
            #expect(result.slots.allSatisfy { $0.width == metrics.pinnedTabWidth })
        }
    }
}
