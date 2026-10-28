import CoreGraphics
@testable import CmuxNextBrowser
import Testing

/// The pure frame layouts the browser's status views and bars lay out with instead of Auto
/// Layout (plans/cmux-next/chrome-parity/p03-rendering.md R4): narrow,
/// normal and wide rooms, right to left, and a row with an accessory (an action button).
@Suite struct PaneChromeFrameLayoutTests {
    // MARK: Column

    @Test func aCenteredColumnStacksTopDownAroundTheMiddle() {
        let column = ChromeColumnLayout(spacing: 10, insets: ChromeInsets(all: 5))
        let items = [CGSize(width: 100, height: 20), CGSize(width: 60, height: 30)]
        #expect(column.size(of: items) == CGSize(width: 110, height: 70))
        let rects = column.place(items, in: CGRect(x: 0, y: 0, width: 110, height: 70))
        #expect(rects == [CGRect(x: 5, y: 45, width: 100, height: 20), CGRect(x: 25, y: 5, width: 60, height: 30)])
    }

    @Test func aLeadingColumnMirrorsRightToLeft() {
        let items = [CGSize(width: 40, height: 10)]
        let box = CGRect(x: 0, y: 0, width: 200, height: 30)
        let ltr = ChromeColumnLayout(spacing: 0, insets: ChromeInsets(top: 0, leading: 8, bottom: 0, trailing: 2), alignment: .leading)
        var rtl = ltr
        rtl.rightToLeft = true
        #expect(ltr.place(items, in: box) == [CGRect(x: 8, y: 20, width: 40, height: 10)])
        #expect(rtl.place(items, in: box) == [CGRect(x: 152, y: 20, width: 40, height: 10)])
    }

    @Test func anItemWiderThanTheColumnIsCutToIt() {
        let column = ChromeColumnLayout(spacing: 0, insets: ChromeInsets(all: 10), alignment: .leading)
        let rects = column.place([CGSize(width: 500, height: 10)], in: CGRect(x: 0, y: 0, width: 120, height: 30))
        #expect(rects == [CGRect(x: 10, y: 10, width: 100, height: 10)])
    }

    // MARK: Row

    @Test func aRowRunsInReadingOrderAndMirrorsRightToLeft() {
        let items = [CGSize(width: 50, height: 20), CGSize(width: 30, height: 28)]
        let box = CGRect(x: 0, y: 0, width: 200, height: 32)
        let ltr = ChromeRowLayout(spacing: 6, insets: ChromeInsets(leading: 12, trailing: 4))
        #expect(ltr.width(of: items) == 102)
        #expect(ltr.place(items, in: box) == [CGRect(x: 12, y: 6, width: 50, height: 20), CGRect(x: 68, y: 2, width: 30, height: 28)])
        var rtl = ltr
        rtl.rightToLeft = true
        #expect(rtl.place(items, in: box) == [CGRect(x: 138, y: 6, width: 50, height: 20), CGRect(x: 102, y: 2, width: 30, height: 28)])
    }

    /// A narrow pill: the text gives up the width, the action and close buttons keep theirs.
    @Test func aNarrowRowShrinksOnlyTheFlexibleItem() {
        let row = ChromeRowLayout(spacing: 6, insets: ChromeInsets(leading: 12, trailing: 4))
        let items = [CGSize(width: 300, height: 16), CGSize(width: 60, height: 24), CGSize(width: 24, height: 24)]
        let rects = row.place(items, in: CGRect(x: 0, y: 0, width: 200, height: 32), flexible: 0)
        #expect(rects.map(\.width) == [88, 60, 24])
        #expect(rects[2].maxX == 196, "the close button keeps the trailing inset")
        // A wide room leaves every item at its size.
        let wide = row.place(items, in: CGRect(x: 0, y: 0, width: 900, height: 32), flexible: 0)
        #expect(wide.map(\.width) == [300, 60, 24])
    }

    /// Answers that fit stay side by side; ones that do not stack in reading order, each as wide
    /// as the row, never past its edges (a narrow prompt bar's three answers).
    @Test func aRowThatDoesNotFitStacksInsideItsBox() {
        let row = ChromeRowLayout(spacing: 6)
        let items = [CGSize(width: 80, height: 28), CGSize(width: 100, height: 28), CGSize(width: 150, height: 28)]
        #expect(row.size(of: items, maxWidth: 342) == CGSize(width: 342, height: 28), "342 fits: one line")
        #expect(row.placeFitting(items, in: CGRect(x: 0, y: 0, width: 342, height: 28)) == row.place(items, in: CGRect(x: 0, y: 0, width: 342, height: 28)))

        #expect(row.size(of: items, maxWidth: 200) == CGSize(width: 200, height: 96))
        let stacked = row.placeFitting(items, in: CGRect(x: 10, y: 0, width: 200, height: 96))
        #expect(stacked == [CGRect(x: 10, y: 68, width: 200, height: 28), CGRect(x: 10, y: 34, width: 200, height: 28),
                            CGRect(x: 10, y: 0, width: 200, height: 28)])
        var rtl = row
        rtl.rightToLeft = true
        #expect(rtl.placeFitting(items, in: CGRect(x: 10, y: 0, width: 200, height: 96)) == stacked, "full-width rows mirror onto themselves")
    }

    // MARK: Page message (error page, sad tab)

    @Test func aPageMessageIsCenteredAndRaisedByTheToolbar() {
        let layout = PageMessageLayout(column: ChromeColumnLayout(spacing: 10), maxWidth: 400, margin: 16, lift: 30)
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(layout.itemWidth(in: bounds) == 400)
        let rects = layout.place([CGSize(width: 200, height: 40), CGSize(width: 100, height: 20)], in: bounds)
        // 70 tall, centered at 300 + 30: from 295 to 365.
        #expect(rects == [CGRect(x: 300, y: 325, width: 200, height: 40), CGRect(x: 350, y: 295, width: 100, height: 20)])
    }

    @Test func aNarrowPageKeepsTheMessageOffItsSides() {
        let layout = PageMessageLayout(column: ChromeColumnLayout(spacing: 0), maxWidth: 400, margin: 16, lift: 0)
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 300)
        #expect(layout.itemWidth(in: bounds) == 168)
        let rects = layout.place([CGSize(width: 168, height: 50)], in: bounds)
        #expect(rects[0].minX == 16 && rects[0].maxX == 184)
    }

    @Test func aShortPageKeepsTheMessageTopOnIt() {
        let layout = PageMessageLayout(column: ChromeColumnLayout(spacing: 0), maxWidth: 400, margin: 16, lift: 40)
        let rects = layout.place([CGSize(width: 100, height: 120)], in: CGRect(x: 0, y: 0, width: 300, height: 100))
        #expect(rects[0].maxY == 100, "taller than the page: its top stays visible")
        let fits = layout.place([CGSize(width: 100, height: 60)], in: CGRect(x: 0, y: 0, width: 300, height: 100))
        #expect(fits[0].maxY == 100, "the lift never pushes it past the page's top")
    }

    // MARK: Glass card (prompt bar, Page unresponsive)

    @Test func aCardTakesItsNaturalWidthBetweenItsBounds() {
        let card = OverlayCardLayout(column: ChromeColumnLayout(spacing: 0, insets: ChromeInsets(all: 10)), minWidth: 240, maxWidth: 360)
        #expect(card.maxItemWidth(room: 1000) == 340)
        #expect(card.maxItemWidth(room: 200) == 180)
        // Short content: the preferred minimum.
        #expect(card.width(natural: [CGSize(width: 50, height: 10)], room: 1000) == 240)
        // Between: its own width.
        #expect(card.width(natural: [CGSize(width: 280, height: 10)], room: 1000) == 300)
        // Long content: the maximum.
        #expect(card.width(natural: [CGSize(width: 340, height: 10)], room: 1000) == 360)
        // A narrow pane narrows the card below its preferred minimum.
        #expect(card.width(natural: [CGSize(width: 50, height: 10)], room: 150) == 150)
        #expect(card.size(width: 300, items: [CGSize(width: 50, height: 10), CGSize(width: 50, height: 30)]) == CGSize(width: 300, height: 60))
    }

    // MARK: Floating cards and the unresponsive card

    @Test func aFloatingCardSitsBottomCenterAboveItsLift() {
        let placement = PageCardPlacement(inset: 8)
        let page = CGSize(width: 600, height: 400)
        #expect(placement.maxWidth(in: page) == 584)
        #expect(placement.frame(for: CGSize(width: 200, height: 32), lift: 0, in: page) == CGRect(x: 200, y: 8, width: 200, height: 32))
        #expect(placement.frame(for: CGSize(width: 200, height: 32), lift: 48, in: page).minY == 56)
        // Narrow: never wider than the page less the insets.
        #expect(placement.frame(for: CGSize(width: 900, height: 32), lift: 0, in: page) == CGRect(x: 8, y: 8, width: 584, height: 32))
    }

    @Test func theUnresponsiveCardIsCenteredOnThePage() {
        let page = CGRect(x: 0, y: 40, width: 500, height: 300)
        #expect(PageStatusViews.centered(CGSize(width: 201, height: 100), in: page) == CGRect(x: 149, y: 140, width: 201, height: 100))
    }
}
