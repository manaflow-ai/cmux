import CoreGraphics
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Leo 2026-10-20: dismissing a sidebar row's hover card took too much travel. The escape-slot
/// layout (`HoverCardEscapeGeometry.RowAlignment.middle`, a Debug Settings switch since the card
/// lines up with its row's top by default) leaves an empty slot beside the row: the slot
/// dismisses, the straight path from the row into the card keeps it, and anywhere off both
/// dismisses. The default, top-aligned layout: `HoverCardRowAlignmentTests`.
@Suite struct HoverCardEscapeGeometryTests {
    /// A 32 pt sidebar row on a 1440 x 900 screen (y up), and a 280 x 160 card.
    private let row = CGRect(x: 8, y: 600, width: 224, height: 32)
    private let size = CGSize(width: 280, height: 160)
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    /// A wide gap, so the gap zone is easy to aim at; the sidebar's own is one device pixel.
    private let gap: CGFloat = 10

    @Test func theCardSitsRightOfTheRowWithItsTopOnTheRowsMiddle() {
        let g = HoverCardEscapeGeometry(anchor: row, cardSize: size, visible: screen, gap: gap, alignment: .middle)
        #expect(g.card.minX == row.maxX + gap)
        #expect(g.card.maxY == row.midY)
        #expect(!g.isLeading)
        #expect(g.escapeSlot == CGRect(x: row.maxX, y: row.midY, width: size.width + gap, height: row.height / 2))
        #expect(g.gapStrip == CGRect(x: row.maxX, y: g.card.minY, width: gap, height: size.height))
    }

    /// Leo 2026-10-20: the card stands off its row, so the row's right end (its x) never touches
    /// it; the gap alone keeps no card.
    @Test func theGapBetweenTheRowAndTheCardKeepsNoCardByItself() {
        let g = HoverCardEscapeGeometry(anchor: row, cardSize: size, visible: screen, gap: gap, alignment: .middle)
        #expect(gap >= 8 && gap <= 12)
        let below = CGPoint(x: row.maxX + 3, y: row.minY - 14)
        #expect(g.zone(at: below) == .gap)
        #expect(!g.keepsCard(at: below))
    }

    @Test func theEscapeSlotDismisses() {
        let g = HoverCardEscapeGeometry(anchor: row, cardSize: size, visible: screen, gap: gap, alignment: .middle)
        // Just right of the row's upper half, and at the slot's far end.
        for point in [CGPoint(x: row.maxX + 1, y: row.maxY - 2), CGPoint(x: row.maxX + size.width - 1, y: row.midY + 1)] {
            #expect(g.zone(at: point) == .escape, "\(point)")
            #expect(!g.keepsCard(at: point), "\(point)")
            #expect(!g.card.contains(point), "the card covers \(point)")
        }
    }

    @Test func theStraightPathFromTheRowIntoTheCardKeepsIt() {
        let g = HoverCardEscapeGeometry(anchor: row, cardSize: size, visible: screen, gap: gap, alignment: .middle)
        // Right from the row's lower half: row, gap (kept by the pointer's aim), then card, never
        // the escape slot or outside.
        let y = row.minY + 4
        var x = row.midX
        while x < g.card.midX {
            let zone = g.zone(at: CGPoint(x: x, y: y))
            #expect(zone == .row || zone == .gap || zone == .card, "the path reaches \(zone) at x \(x)")
            x += 0.5
        }
        #expect(g.card.isAimedAt(from: CGPoint(x: row.maxX - 2, y: y), to: CGPoint(x: row.maxX + 2, y: y)),
                "a pointer moving right across the gap does not aim at the card")
        // Down-right from the row's lower half, past the gap, into the card's top-left corner.
        #expect(g.zone(at: CGPoint(x: g.card.minX + 2, y: row.midY - 2)) == .card)
    }

    @Test func leavingBothTheRowAndTheCardDismisses() {
        let g = HoverCardEscapeGeometry(anchor: row, cardSize: size, visible: screen, gap: gap, alignment: .middle)
        let off = [
            CGPoint(x: g.card.maxX + 10, y: g.card.midY), // past the card's far edge
            CGPoint(x: g.card.midX, y: g.card.minY - 10), // below the card
            CGPoint(x: row.maxX + 20, y: row.maxY + 10), // above the slot
            CGPoint(x: row.midX, y: row.minY - 40), // down the sidebar, off the row
        ]
        for point in off {
            #expect(g.zone(at: point) == .outside, "\(point)")
            #expect(!g.keepsCard(at: point), "\(point)")
        }
    }

    /// Near the screen's bottom the card flips above the row's middle and the slot moves below
    /// it: the screen clamp never pushes the card over the slot.
    @Test func nearTheScreensBottomTheCardFlipsAndKeepsTheSlot() {
        let low = CGRect(x: 8, y: 40, width: 224, height: 32)
        let g = HoverCardEscapeGeometry(anchor: low, cardSize: size, visible: screen, gap: gap, alignment: .middle)
        #expect(g.card.minY == low.midY)
        #expect(g.escapeSlot == CGRect(x: low.maxX, y: low.minY, width: size.width + gap, height: low.height / 2))
        #expect(g.zone(at: CGPoint(x: low.maxX + 4, y: low.minY + 2)) == .escape)
        #expect(g.zone(at: CGPoint(x: low.maxX + 4, y: low.maxY - 2)) == .gap)
        #expect(g.zone(at: CGPoint(x: low.maxX + gap + 4, y: low.maxY - 2)) == .card)
    }

    /// A sidebar at the screen's right edge: the card goes left of the row, the slot with it.
    @Test func atTheScreensRightEdgeTheCardGoesLeftAndKeepsTheSlot() {
        let right = CGRect(x: 1200, y: 600, width: 232, height: 32)
        let g = HoverCardEscapeGeometry(anchor: right, cardSize: size, visible: screen, gap: gap, alignment: .middle)
        #expect(g.isLeading)
        #expect(g.card.maxX == right.minX - gap)
        #expect(g.zone(at: CGPoint(x: right.minX - 4, y: right.maxY - 2)) == .escape)
        #expect(g.zone(at: CGPoint(x: right.minX - 4, y: right.minY + 2)) == .gap)
        #expect(g.zone(at: CGPoint(x: right.minX - gap - 4, y: right.minY + 2)) == .card)
    }

    /// Lawrence 2026-10-21: "horizontally only 1 pixel gap". At every scale the card's near edge is
    /// exactly one device pixel past the device pixel the sidebar's edge falls on, on both sides.
    @Test(arguments: [1, 2, 3] as [CGFloat])
    func theNearEdgeIsOnePixelPastTheEdgesPixel(scale: CGFloat) {
        let fractional = CGRect(x: 8.3, y: 600.3, width: 224.1, height: 31.7)
        let g = HoverCardEscapeGeometry(anchor: fractional, cardSize: size, visible: screen, scale: scale)
        let edge = (fractional.maxX * scale).rounded() / scale
        #expect(abs(g.card.minX - (edge + 1 / scale)) < 0.0001, "@\(scale)x: \(g.card.minX - edge) pt off the edge's pixel")
        #expect(HoverCardEscapeGeometry.edgeGap(scale: scale) == 1 / scale)
        let right = CGRect(x: 1440 - 240.3, y: 600, width: 240.3, height: 32)
        let leading = HoverCardEscapeGeometry(anchor: right, cardSize: size, visible: screen, scale: scale)
        let leftEdge = (right.minX * scale).rounded() / scale
        #expect(leading.isLeading)
        #expect(abs(leading.card.maxX - (leftEdge - 1 / scale)) < 0.0001, "@\(scale)x leading: \(leftEdge - leading.card.maxX) pt")
    }

    /// A row's anchor is its height across the whole sidebar column: a row's inset, trim or group
    /// depth never moves the card sideways.
    @Test func aRowsBandSpansTheColumn() {
        let column = CGRect(x: 0, y: 0, width: 260, height: 900)
        let nested = CGRect(x: 36, y: 500, width: 190, height: 28)
        let band = HoverCardEscapeGeometry.rowBand(row: nested, column: column)
        #expect(band == CGRect(x: 0, y: 500, width: 260, height: 28))
        let top = HoverCardEscapeGeometry(anchor: band, cardSize: size, visible: screen, scale: 2)
        #expect(top.card.minX == 260.5)
        #expect(top.card.maxY == nested.maxY)
    }
}
