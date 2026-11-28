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
        var metrics = TabStripMetrics.standard
        metrics.crowdedMarks = .trailing
        let longTitle = TabItem(id: TabID("long"), title: "A long tab title", icon: .icon(.browser), status: .success)
        let shortTitle = TabItem(id: TabID("short"), title: "A", icon: .icon(.browser), status: .success)
        let threshold = max(metrics.titleMinVisibleWidth, ceil(Typography.tabTitle.pointSize * 0.55 * 3))
        let titleX = metrics.contentLeadingInset + metrics.iconSize + metrics.iconTitleSpacing
        let width = 2 * metrics.tabBackgroundInset + titleX + metrics.contentTrailingInset + metrics.badgeSize + Metrics.space2 + threshold - 1

        let clipped = TabCell(item: longTitle)
        clipped.metrics = metrics
        clipped.frame = CGRect(x: 0, y: 0, width: width, height: metrics.tabHeight)
        #expect(clipped.visibility.showsTitle)
        #expect((try #require(clipped.titleFade.geometry).visibleWidth) < threshold)
        #expect(clipped.titleLayer.opacity == 0, "a status should not leave a one- or two-character title sliver")

        let short = TabCell(item: shortTitle)
        short.metrics = metrics
        short.frame = CGRect(x: 0, y: 0, width: width, height: metrics.tabHeight)
        #expect(short.visibility.showsTitle)
        #expect(short.titleLayer.opacity == 1, "a title shorter than the hide threshold should remain visible")
    }

    /// Leo 2026-11-27: "ok why dont your tabs have any names/letters showing up? that intentional?" A crowded agent
    /// tab whose status leaves its title under the minimum draws the status on its icon and keeps its title.
    @Test func crowdedStatusMovesOntoTheIconAndTheTitleStays() throws {
        let metrics = TabStripMetrics.standard
        #expect(metrics.crowdedMarks == .onIcon)
        let item = TabItem(id: TabID("agent"), title: "claude: crowded tab titles", icon: .icon(.browser), status: .success)
        let threshold = max(metrics.titleMinVisibleWidth, ceil(Typography.tabTitle.pointSize * 0.55 * 3))
        let titleX = metrics.contentLeadingInset + metrics.iconSize + metrics.iconTitleSpacing
        let width = 2 * metrics.tabBackgroundInset + titleX + metrics.contentTrailingInset + metrics.badgeSize + Metrics.space2 + threshold - 1

        let cell = TabCell(item: item)
        cell.frame = CGRect(x: 0, y: 0, width: width, height: metrics.tabHeight)
        #expect(cell.visibility.showsTitle)
        #expect(cell.titleLayer.opacity == 1, "the title keeps its letters; the status moves onto the icon")
        #expect((try #require(cell.titleFade.geometry).visibleWidth) >= threshold)
    }

    /// `.dropBadges` keeps the status beside the title, so a status alone still hides a title it squeezes.
    @Test func dropBadgesKeepsTheStatusTrailing() {
        var metrics = TabStripMetrics.standard
        metrics.crowdedMarks = .dropBadges
        let item = TabItem(id: TabID("agent"), title: "claude: crowded tab titles", icon: .icon(.browser), status: .success)
        let threshold = max(metrics.titleMinVisibleWidth, ceil(Typography.tabTitle.pointSize * 0.55 * 3))
        let titleX = metrics.contentLeadingInset + metrics.iconSize + metrics.iconTitleSpacing
        let width = 2 * metrics.tabBackgroundInset + titleX + metrics.contentTrailingInset + metrics.badgeSize + Metrics.space2 + threshold - 1

        let cell = TabCell(item: item)
        cell.metrics = metrics
        cell.frame = CGRect(x: 0, y: 0, width: width, height: metrics.tabHeight)
        #expect(cell.titleLayer.opacity == 0)
    }
}
