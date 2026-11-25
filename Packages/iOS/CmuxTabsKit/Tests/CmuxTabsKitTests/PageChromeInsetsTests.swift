@testable import CmuxTabsKit
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Testing

/// The page's insets under the chrome with the Safari bar at the top. Leo 2026-11-24: "when
/// scrolling situation, we recently moved the safarilike thing to the top, which is good, but
/// we need to then fix the screens splitting between scrolling and whatnot". Scrolling collapses
/// the top bar into its pill under the status bar; the page kept the expanded bar's inset, so a
/// dead strip sat between the pill and the content. The live inset follows the pill.
struct PageChromeInsetsTests {
    // The kit's default metrics (TabsKitTheme.Metrics): top bar gap 2, control 48, pill 32 high.
    private let gap: CGFloat = 2, control: CGFloat = 48, pill: CGFloat = 32

    private func resting(safeTop: CGFloat, safeBottom: CGFloat) -> PageChromeInsets {
        PageChromeInsets.restingTop(safeTop: safeTop, safeBottom: safeBottom, gap: gap, control: control)
    }

    /// Expanded, the page starts 8 pt under the bar's row (portrait iPhone, 62 pt status bar).
    @Test func restingTopIsUnderTheExpandedBar() {
        let r = resting(safeTop: 62, safeBottom: 34)
        #expect(r.top == CGFloat(62 + 2 + 48 + 8))
        #expect(r.bottom == 34)
        #expect(PageChromeInsets.live(edge: .top, collapsed: false, resting: r, safeTop: 62, pillHeight: pill) == r)
    }

    /// Collapsed, the page's top rises to 8 pt under the pill: the band the bar left is the
    /// page's, not a strip between the pill and the content (the split).
    @Test func collapsedTopBarGivesItsBandBack() {
        let r = resting(safeTop: 62, safeBottom: 34)
        let live = PageChromeInsets.live(edge: .top, collapsed: true, resting: r, safeTop: 62, pillHeight: pill)
        let pillBottom = PageChromeInsets.collapsedTopPillY(safeTop: 62, pillHeight: pill) + pill
        #expect(live.top == pillBottom + 8)
        #expect(live.top == 94)
        #expect(live.top < r.top)
        // Still under the status bar, and the bottom (the composer's edge) does not move.
        #expect(live.top >= 62)
        #expect(live.bottom == r.bottom)
    }

    /// Landscape (no status bar): the bar sits 20 pt down; collapsed, the page reaches the pill.
    @Test func landscapeCollapsedTopBar() {
        let r = resting(safeTop: 0, safeBottom: 21)
        #expect(r.top == CGFloat(20 + 2 + 48 + 8))
        let live = PageChromeInsets.live(edge: .top, collapsed: true, resting: r, safeTop: 0, pillHeight: pill)
        #expect(live.top == 0 + pill + 8)
        #expect(live.bottom == 21)
    }

    /// A bottom bar's collapse keeps Safari's insets: the page already scrolls under it.
    @Test func bottomBarCollapseKeepsTheRestingInsets() {
        let r = PageChromeInsets(top: 62, bottom: 120)
        #expect(PageChromeInsets.live(edge: .bottom, collapsed: true, resting: r, safeTop: 62, pillHeight: pill) == r)
    }

    /// A pill taller than the bar never pushes the page below its resting line.
    @Test func liveNeverExceedsResting() {
        let r = resting(safeTop: 62, safeBottom: 34)
        let live = PageChromeInsets.live(edge: .top, collapsed: true, resting: r, safeTop: 62, pillHeight: 200)
        #expect(live.top == r.top)
    }

    /// The composer's floor: a top bar's collapse leaves the bottom alone, so the floor holds
    /// collapsed too; a bottom bar's collapse lowers it.
    @Test func accessoryFloorHoldsUnderACollapsedTopBar() {
        #expect(PageChromeInsets.accessoryRestsOnBar(edge: .top, collapsed: true))
        #expect(PageChromeInsets.accessoryRestsOnBar(edge: .top, collapsed: false))
        #expect(PageChromeInsets.accessoryRestsOnBar(edge: .bottom, collapsed: false))
        #expect(!PageChromeInsets.accessoryRestsOnBar(edge: .bottom, collapsed: true))
    }
}
