import Testing
import Foundation
import CoreGraphics
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextTabs

@MainActor
struct TabCellTitleTruncationTests {
    @Test func tabTitlesStartWithoutCoreTextTruncation() {
        let cell = TabCell(item: TabItem(id: TabID("helper-1"), title: "Helper 1"))

        #expect(cell.titleLayer.truncation == nil)
    }

    @Test func clippedTitleUsesVisibleWidthAtRestAndFullSpanForMarquee() {
        let geometry = TitleFadeGeometry(textWidth: 160, span: 120, visibleWidth: 72,
                                         leadingPadding: 8, trailingPadding: 0, fadeWidth: 12,
                                         restWidth: 72)

        #expect(geometry.layerWidth(marquee: false) == 72)
        #expect(geometry.layerWidth(marquee: true) == 160)
    }

    @Test func hidesAStatusClippedSliverButKeepsARealShortTitle() throws {
        let metrics = TabStripMetrics.standard
        let longTitle = TabItem(id: TabID("long"), title: "A long tab title", icon: .icon(.browser), status: .success)
        let shortTitle = TabItem(id: TabID("short"), title: "A", icon: .icon(.browser), status: .success)
        let threshold = max(metrics.titleMinVisibleWidth, ceil(Typography.tabTitle.pointSize * 0.55 * 3))
        let titleX = metrics.contentLeadingInset + metrics.iconSize + metrics.iconTitleSpacing
        let width = 2 * metrics.tabBackgroundInset + titleX + metrics.contentTrailingInset + metrics.badgeSize + Metrics.space2 + threshold - 1

        let clipped = TabCell(item: longTitle)
        clipped.frame = CGRect(x: 0, y: 0, width: width, height: metrics.tabHeight)
        #expect(clipped.visibility.showsTitle)
        #expect((try #require(clipped.titleFade.geometry).visibleWidth) < threshold)
        #expect(clipped.titleLayer.opacity == 0, "a status should not leave a one- or two-character title sliver")

        let short = TabCell(item: shortTitle)
        short.frame = CGRect(x: 0, y: 0, width: width, height: metrics.tabHeight)
        #expect(short.visibility.showsTitle)
        #expect(short.titleLayer.opacity == 1, "a title shorter than the hide threshold should remain visible")
    }
}
