import AppKit
@testable import CmuxNextTabs
import Testing

/// The tab hover card lays out by frames from ``TabHoverCardLayout``, a pure
/// function of its metrics and its measured content, and reports that size to the panel that hosts
/// it, as a Chromium view does (`CalculatePreferredSize` and `Layout()`). Before, every hover
/// retarget solved the card's constraints on the main thread.
@MainActor @Suite struct TabHoverCardFrameLayoutTests {
    private let metrics = TabHoverCardLayout.Metrics(cardWidth: 248, padding: 12, iconSize: 13, indicatorSize: 13, gap: 6, thumbnailGap: 12)

    private func content(kindIcon: Bool = true, activity: Bool = true, rows: [CGFloat] = [16, 16],
                         thumbnail: CGFloat? = 140) -> TabHoverCardLayout.Content {
        TabHoverCardLayout.Content(showsKindIcon: kindIcon, showsActivity: activity, titleHeight: 17, titleBaseline: 13,
                                   rowHeights: rows, thumbnailHeight: thumbnail)
    }

    @Test func theTitleWrapsBetweenTheGlyphAndTheIndicator() {
        #expect(TabHoverCardLayout.titleWidth(metrics: metrics, showsKindIcon: true, showsActivity: true) == 248 - 31 - 31)
        #expect(TabHoverCardLayout.titleWidth(metrics: metrics, showsKindIcon: false, showsActivity: false) == 248 - 24)
    }

    @Test func aFullCardStacksTitleRowsAndThumbnail() {
        let layout = TabHoverCardLayout(content: content(), metrics: metrics)
        // 12 + 17 title + 6 + 16 + 6 + 16 rows + 12 + 140 thumbnail + 12.
        #expect(layout.size == CGSize(width: 248, height: 237))
        #expect(layout.title == CGRect(x: 31, y: 237 - 12 - 17, width: 186, height: 17))
        #expect(layout.rows == [CGRect(x: 12, y: 237 - 51, width: 224, height: 16), CGRect(x: 12, y: 237 - 73, width: 224, height: 16)])
        #expect(layout.thumbnail == CGRect(x: 12, y: 12, width: 224, height: 140))
        // The glyph centers a third of its height above the title's baseline (13 pt below the card's 12 pt padding).
        #expect(abs(layout.kindIcon.midY - (237 - (12 + 13 - 13.0 / 3))) < 0.001)
        #expect(layout.kindIcon.minX == 12)
        #expect(layout.activity.maxX == 236)
    }

    @Test func aCardWithNoRowsOrThumbnailEndsUnderTheTitle() {
        let layout = TabHoverCardLayout(content: content(kindIcon: false, activity: false, rows: [], thumbnail: nil), metrics: metrics)
        #expect(layout.size.height == 12 + 17 + 12)
        #expect(layout.title.minX == 12)
        #expect(layout.title.width == 224)
    }

    @Test func rightToLeftMirrorsTheCard() {
        let ltr = TabHoverCardLayout(content: content(), metrics: metrics)
        let rtl = TabHoverCardLayout(content: content(), metrics: metrics, rightToLeft: true)
        #expect(rtl.size == ltr.size)
        #expect(rtl.kindIcon.maxX == 248 - 12, "the glyph leads from the right edge")
        #expect(rtl.activity.minX == 12, "the indicator trails at the left edge")
        #expect(rtl.title.minX == 248 - ltr.title.maxX)
        #expect(rtl.thumbnail == ltr.thumbnail, "a centered thumbnail mirrors onto itself")
    }

    @Test func theCardReportsItsLayoutSizeAndHoldsNoConstraints() {
        _ = NSApplication.shared
        let card = TabHoverCardView()
        card.configure(.tab(TabItem(id: TabID("t"), title: "A long title that wraps onto a second line in the card", subtitle: "~/Projects/cmux")))
        card.setThumbnailVisible(true)
        let size = card.fittingSize
        #expect(size == card.cardLayout.size)
        #expect(size.width == TabHoverCardView.cardWidth)
        #expect(card.intrinsicContentSize == size)
        #expect(card.constraints.allSatisfy { String(describing: type(of: $0)) != "NSLayoutConstraint" }, "the card holds constraints of its own")
        #expect(card.subviews.allSatisfy { $0.translatesAutoresizingMaskIntoConstraints }, "a subview opted out of frame layout")

        card.frame = CGRect(origin: .zero, size: size)
        card.layoutSubtreeIfNeeded()
        let title = card.titleLabel.alignmentRect(forFrame: card.titleLabel.frame), expected = card.cardLayout.title
        #expect(abs(title.minX - expected.minX) < 0.01 && abs(title.minY - expected.minY) < 0.01)
        #expect(abs(title.width - expected.width) < 0.01 && abs(title.height - expected.height) < 0.01)

        card.setThumbnailVisible(false)
        let gap = TabHoverCardView.layoutMetrics.thumbnailGap
        #expect(card.fittingSize.height == size.height - TabHoverCardView.thumbnailSize.height - gap,
                "hiding the thumbnail gives up its height and its gap")
    }
}
