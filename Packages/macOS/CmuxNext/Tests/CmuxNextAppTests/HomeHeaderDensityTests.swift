import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextHome
import CoreGraphics
import Testing

/// The Home list's header follows the sidebar's `sidebar.density` and `sidebar.textSize` (the user,
/// 2026-11-04: the Sidebar States Playground's Home filter columns, 3 densities by 3 text sizes, all
/// looked the same). Compact with the default text keeps today's sizes; a bigger density or text
/// size grows the filter circle, the search field, the Unread chip and their text.
struct HomeHeaderDensityTests {
    /// The app's default tokens (`Metrics`, `Typography` at Interface Size 100 %).
    static let base = SidebarRowTokens.Base(rowHeight: 24, space1: 2, space2: 4, space3: 6, space4: 8,
                                            cornerRadius: 6, body: 13, caption: 11)

    static func metrics(_ density: SidebarDensity, _ textSize: SidebarTextSize) -> HomeSidebarHeaderMetrics {
        HomeSidebarHeaderMetrics(tokens: SidebarRowTokens(density: density, textSize: textSize, base: base),
                                 detail: TypeScale.Base.detail, caption: TypeScale.Base.caption)
    }

    @Test func compactDefaultKeepsTodaysSizes() {
        let m = Self.metrics(.compact, .small)
        #expect(m == .standard)
        #expect(m.side == 30 && m.chipHeight == 24 && m.chipGap == 6 && m.chipPadding == 10)
        #expect(m.chipFontSize == 12 && m.chipGlyphSize == 9 && m.emptyTextStep == 0)
        let h = HomeSidebarHeaderLayout(width: 320, searchOpen: false, filterOn: true, metrics: m)
        #expect(h == HomeSidebarHeaderLayout(width: 320, searchOpen: false, filterOn: true))
        #expect(h.filter.height == 30 && h.search.height == 30 && h.filterChip.height == 24)
        #expect(h.listTop == HomeSidebarHeaderLayout.band + 24 + 6)
    }

    @Test func comfortableLargerIsBigger() {
        let small = Self.metrics(.compact, .small)
        let big = Self.metrics(.comfortable, .large)
        #expect(big.side > small.side && big.chipHeight > small.chipHeight && big.chipPadding > small.chipPadding)
        #expect(big.chipFontSize > small.chipFontSize && big.chipGlyphSize > small.chipGlyphSize && big.emptyTextStep > 0)
        let h = HomeSidebarHeaderLayout(width: 320, searchOpen: false, filterOn: true, metrics: big)
        let before = HomeSidebarHeaderLayout(width: 320, searchOpen: false, filterOn: true, metrics: small)
        #expect(h.filter.height == big.side && h.search.height == big.side && h.filterChip.height == big.chipHeight)
        #expect(h.filter.height > before.filter.height && h.filterChip.height > before.filterChip.height)
        #expect(h.listTop > before.listTop)
        // The bigger row still fits in the band, and on one row.
        #expect(h.filter.minY >= 0 && h.filter.maxY <= HomeSidebarHeaderLayout.band && h.search.midY == h.filter.midY)
    }

    /// Each step up in density or text size grows the circle and the chip text; no two of the
    /// playground's Normal and Comfortable columns at one text size look the same. (Compact steps from
    /// its own smaller base, `SidebarTextSize.steps(compact:)`, so its Medium and Large reach Comfortable's.)
    @Test(arguments: SidebarTextSize.allCases)
    func comfortableIsBiggerThanNormal(_ textSize: SidebarTextSize) {
        let normal = Self.metrics(.normal, textSize)
        let comfortable = Self.metrics(.comfortable, textSize)
        #expect(comfortable.side > normal.side && comfortable.chipHeight > normal.chipHeight)
        #expect(comfortable.chipFontSize == normal.chipFontSize)
        #expect(comfortable.side >= Self.metrics(.compact, textSize).side)
    }

    /// The header is a band above the list: at Expanded it takes Comfortable's sizes
    /// (``SidebarRowTokens/band``), so the playground's Expanded column is not Compact's.
    @Test(arguments: SidebarTextSize.allCases)
    func expandedIsComfortable(_ textSize: SidebarTextSize) {
        let expanded = Self.metrics(.expanded, textSize)
        #expect(expanded == Self.metrics(.comfortable, textSize))
        #expect(expanded.side > Self.metrics(.normal, textSize).side)
    }

    @Test func largerTextIsBiggerText() {
        let standard = Self.metrics(.compact, .small)
        let large = Self.metrics(.compact, .medium)
        let larger = Self.metrics(.compact, .large)
        #expect(standard.chipFontSize < large.chipFontSize && large.chipFontSize < larger.chipFontSize)
        #expect(standard.side < large.side && large.side < larger.side)
    }
}
