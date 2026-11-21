@testable import CmuxTabsKit
import CoreGraphics
import Testing

/// iPhone 17 Pro Max: 440 x 956 pt, 62 pt top / 34 pt bottom safe area.
private func proMax(count: Int) -> OverviewLayout {
    OverviewLayout(size: CGSize(width: 440, height: 956), safeTop: 62, safeBottom: 34, count: count)
}

struct OverviewLayoutTests {
    /// One tab: a larger centred card (device Pro Max 294.7 pt at x 72.7;
    /// simulator Pro 268 pt at x 66.7, top 122, bottom 500).
    @Test func loneTabIsALargerCentredCard() {
        let pro = OverviewLayout(size: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34, count: 1)
        let r = pro.card(0)
        #expect(r.width == 268 && r.minX == 67 && r.minY == 122)
        #expect(abs(r.maxY - 500) < 1)
        let max = proMax(count: 1).card(0)
        #expect(abs(max.width - 294.7) < 2 && abs(max.midX - 220) < 0.5)
        // Two tabs: back to columns.
        #expect(proMax(count: 2).card(0).width == 196)
    }

    /// Device screenshot (iPhone 17 Pro Max, 3x): 196 pt cards with a
    /// 15.2 pt continuous corner.
    @Test func proMaxCardCornerMatchesTheDevice() {
        let g = proMax(count: 2)
        #expect(g.cardWidth == 196)
        #expect(abs(g.cardRadius - 15.2) < 0.1)
    }

    /// Grid metrics measured on the device recordings.
    @Test func proMaxMetricsMatchSafari() {
        let g = proMax(count: 7)
        #expect(g.cardWidth == 196)
        #expect(abs(g.cardHeight - 276) < 0.5)
        #expect(g.card(0).origin == CGPoint(x: 16, y: 122))
        #expect(g.card(1).minX == 228)
        #expect(abs(g.card(5).minY - 752) < 0.5)
        // safari-scroll-into-view-device.mp4: fully scrolled, row 2 sits at 244.
        #expect(abs(g.maxOffset - 508) < 2)
    }

    /// The zoom endpoint is the card's frame converted to the screen at the
    /// grid's scroll offset, also for cards partly or wholly off screen.
    @Test(arguments: [0.0, 120, 315, 400, 508])
    func endpointIsTheCardsScreenFrame(offset: CGFloat) {
        let g = proMax(count: 7)
        for i in 0..<7 {
            let e = g.screenFrame(i, offset: offset)
            #expect(e == g.card(i).offsetBy(dx: 0, dy: -offset))
            #expect(e.size == CGSize(width: g.cardWidth, height: g.cardHeight))
        }
        // At offset 400 the first row is above the screen and the last row is
        // cut off by the bottom: frames still follow the content exactly.
        if offset == 400 {
            #expect(g.screenFrame(0, offset: 400).maxY < 0)
            #expect(!g.isFullyVisible(6, offset: 400))
        }
    }

    /// The endpoint goes through the grid's reported content origin (its
    /// actual scroll position), not a requested offset.
    @Test func endpointFollowsTheReportedContentOrigin() {
        let g = proMax(count: 8)
        // The grid could only scroll to 300 although 508 was requested.
        let e = g.zoomEndpoint(7, contentOrigin: CGPoint(x: 0, y: -300), fallbackOffset: 508)
        #expect(e == g.screenFrame(7, offset: 300))
        #expect(e.maxY > 956)  // off the bottom of the screen
        #expect(g.zoomEndpoint(0, contentOrigin: nil, fallbackOffset: 120) == g.screenFrame(0, offset: 120))
    }

    /// Recorded cases: index 5 and 6 of 7 from offset 0 both end at 508.
    @Test func revealMatchesTheRecording() {
        let g = proMax(count: 7)
        #expect(abs(g.offset(revealing: 5, from: 0) - g.maxOffset) < 0.5)
        #expect(abs(g.offset(revealing: 6, from: 0) - g.maxOffset) < 0.5)
        // Already fully visible: the offset is kept.
        #expect(g.offset(revealing: 2, from: 0) == 0)
        #expect(g.offset(revealing: 4, from: 508) == 508)
    }

    @Test func revealedCardIsFullyVisible() {
        let g = proMax(count: 24)
        for i in 0..<24 {
            for start in stride(from: 0.0, through: Double(g.maxOffset), by: 137) {
                let o = g.offset(revealing: i, from: CGFloat(start))
                #expect(o >= 0 && o <= g.maxOffset)
                #expect(g.isFullyVisible(i, offset: o), "card \(i) from \(start)")
            }
        }
    }

    @Test func revealScrollsUpToACardAboveTheScreen() {
        let g = proMax(count: 24)
        let o = g.offset(revealing: 2, from: 2000)
        #expect(abs(g.screenFrame(2, offset: o).minY - g.top) < 0.5)
    }

    /// Drag to reorder: the slot under the finger, gaps counting as the
    /// nearest card.
    @Test func slotUnderTheFinger() {
        let g = OverviewLayout(size: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34, count: 5)
        for i in 0..<5 {
            let c = g.card(i)
            #expect(g.slot(at: CGPoint(x: c.midX, y: c.midY)) == i)
        }
        #expect(g.slot(at: CGPoint(x: g.card(0).maxX + 4, y: g.card(0).midY)) == 0)
        #expect(g.slot(at: CGPoint(x: g.card(4).midX, y: g.card(4).maxY + 200)) == nil)
    }

    /// Safari, one pinned tab: a 177 x 30 capsule at (16, 122); the grid
    /// starts 16 pt below it, at 168.
    @Test func pinnedCapsulesSitAboveTheGrid() {
        let g = OverviewLayout(size: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34, count: 5, pinned: 1)
        #expect(g.card(0) == CGRect(x: 16, y: 122, width: 177, height: 30))
        #expect(g.card(1).minY == 168 && g.card(1).minX == 16)
        #expect(g.card(2).minX == 209)
        #expect(!g.isLone)
    }

    /// A card's content anchor (cardContentOffset) moves with the zoom: none
    /// full screen, all of it at the card's width, linear in between.
    @Test func cardAnchorFollowsTheZoomScale() {
        let g = OverviewLayout(size: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34, count: 5)
        #expect(g.cardAnchorFraction(402) == 0)
        #expect(g.cardAnchorFraction(g.cardWidth) == 1)
        #expect(abs(g.cardAnchorFraction((402 + g.cardWidth) / 2) - 0.5) < 1e-9)
        #expect(g.cardAnchorFraction(g.cardWidth - 20) == 1)
        // The page points a card shows: the page width at the card's aspect.
        #expect(abs(g.cardPageHeight - 402 * 249.3 / 177) < 1e-9)
    }

    /// An unfolded foldable (about 800 pt wide, nearly square): more columns of
    /// phone-sized cards, centred, instead of two cards 380 pt wide; every
    /// iPhone width keeps Safari's two.
    @Test func wideScreenAddsColumns() {
        for width: CGFloat in [375, 402, 440, 500] { #expect(OverviewLayout.columns(width: width) == 2) }
        let wide = OverviewLayout(size: CGSize(width: 800, height: 700), safeTop: 24, safeBottom: 20, count: 9)
        #expect(wide.columns == 4)
        #expect(wide.cardWidth <= OverviewLayout.maxColumnCard)
        #expect(wide.card(3).minY == wide.card(0).minY && wide.card(4).minY > wide.card(0).minY)
        #expect(abs(wide.card(0).minX - (800 - wide.card(3).maxX)) <= 1)
        #expect(wide.card(1).minX - wide.card(0).maxX == OverviewLayout.gridInset)
        #expect(wide.rows == 3)
        // A lone tab stays a phone's lone card, not two thirds of the wide screen.
        let lone = OverviewLayout(size: CGSize(width: 800, height: 700), safeTop: 24, safeBottom: 20, count: 1)
        #expect(lone.cardWidth == OverviewLayout.maxLoneCard)
        // The host's card picture scale follows the same grid.
        #expect(TabsKitGrid(pageWidth: 800).cardScale(lone: false) == wide.cardWidth / 800)
        #expect(TabsKitGrid(pageWidth: 402).cardScale(lone: false) == 177.0 / 402)
    }

    /// Folding or unfolding under a settled grid keeps the grid's place: the
    /// card that led the screen still leads it in the new column count.
    @Test func resizeKeepsTheGridsPlace() {
        let folded = OverviewLayout(size: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34, count: 40)
        let unfolded = OverviewLayout(size: CGSize(width: 800, height: 700), safeTop: 24, safeBottom: 20, count: 40)
        // Folded, scrolled so card 20 (row 10) leads the screen.
        let atTwenty = folded.card(20).minY - folded.top
        let wide = folded.offset(keepingPlace: atTwenty, in: unfolded)
        // Card 20 is on the first row's line again (the safe area changes with the fold).
        #expect(abs(unfolded.card(20).minY - unfolded.pinnedTop - wide) < 1e-9)
        #expect(wide > 0 && wide <= unfolded.maxOffset)
        // And back: card 20 leads the folded screen again.
        let back = unfolded.offset(keepingPlace: wide, in: folded)
        #expect(abs(back - atTwenty) < 1e-9)
        // At the top it stays at the top; past the end it clamps to the content.
        #expect(folded.offset(keepingPlace: 0, in: unfolded) == 0)
        #expect(folded.offset(keepingPlace: folded.maxOffset, in: unfolded) == unfolded.maxOffset)
    }

    /// A grid scrolled into its pinned section keeps its place too: the
    /// leading pinned capsule leads again, instead of the grid jumping to the top.
    @Test func resizeKeepsThePinnedSectionsPlace() {
        let unfolded = OverviewLayout(size: CGSize(width: 800, height: 700), safeTop: 24, safeBottom: 20, count: 110, pinned: 100)
        let folded = OverviewLayout(size: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34, count: 110, pinned: 100)
        // Unfolded (4 columns), scrolled so pinned capsule 20 (row 5) is on the first row's line.
        let at = unfolded.card(20).minY - unfolded.pinnedTop
        let narrow = unfolded.offset(keepingPlace: at, in: folded)
        // Folded (2 columns): capsule 20 (row 10) is on that line again, though the safe area changed.
        #expect(abs(folded.card(20).minY - folded.pinnedTop - narrow) < 1e-9)
        #expect(narrow > at)
        #expect(abs(folded.offset(keepingPlace: narrow, in: unfolded) - at) < 1e-9)
    }
}
