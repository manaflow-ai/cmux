import CoreGraphics
@testable import CmuxNextDesign
import Testing

/// Leo 2026-10-20: dismissing a sidebar row's hover card took too much travel. The card now
/// leaves an empty escape slot beside the row (`HoverCardEscapeGeometry`): the slot dismisses,
/// the straight path from the row into the card keeps it, and anywhere off both dismisses.
@Suite struct HoverCardEscapeGeometryTests {
    /// A 32 pt sidebar row on a 1440 x 900 screen (y up), and a 280 x 160 card.
    private let row = CGRect(x: 8, y: 600, width: 224, height: 32)
    private let size = CGSize(width: 280, height: 160)
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func theCardSitsRightOfTheRowWithItsTopOnTheRowsMiddle() {
        let g = HoverCardEscapeGeometry(anchor: row, cardSize: size, visible: screen)
        #expect(g.card.minX == row.maxX)
        #expect(g.card.maxY == row.midY)
        #expect(!g.isLeading)
        #expect(g.escapeSlot == CGRect(x: row.maxX, y: row.midY, width: size.width, height: row.height / 2))
    }

    @Test func theEscapeSlotDismisses() {
        let g = HoverCardEscapeGeometry(anchor: row, cardSize: size, visible: screen)
        // Just right of the row's upper half, and at the slot's far end.
        for point in [CGPoint(x: row.maxX + 1, y: row.maxY - 2), CGPoint(x: row.maxX + size.width - 1, y: row.midY + 1)] {
            #expect(g.zone(at: point) == .escape, "\(point)")
            #expect(!g.keepsCard(at: point), "\(point)")
            #expect(!g.card.contains(point), "the card covers \(point)")
        }
    }

    @Test func theStraightPathFromTheRowIntoTheCardKeepsIt() {
        let g = HoverCardEscapeGeometry(anchor: row, cardSize: size, visible: screen)
        // Right from the row's lower half: row, then card, never a point that drops the card.
        let y = row.minY + 4
        var x = row.midX
        while x < g.card.midX {
            #expect(g.keepsCard(at: CGPoint(x: x, y: y)), "the path drops the card at x \(x)")
            x += 0.5
        }
        // Down-right from the row's lower half straight into the card's top-left corner.
        #expect(g.zone(at: CGPoint(x: row.maxX + 2, y: row.midY - 2)) == .card)
    }

    @Test func leavingBothTheRowAndTheCardDismisses() {
        let g = HoverCardEscapeGeometry(anchor: row, cardSize: size, visible: screen)
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
        let g = HoverCardEscapeGeometry(anchor: low, cardSize: size, visible: screen)
        #expect(g.card.minY == low.midY)
        #expect(g.escapeSlot == CGRect(x: low.maxX, y: low.minY, width: size.width, height: low.height / 2))
        #expect(g.zone(at: CGPoint(x: low.maxX + 4, y: low.minY + 2)) == .escape)
        #expect(g.zone(at: CGPoint(x: low.maxX + 4, y: low.maxY - 2)) == .card)
    }

    /// A sidebar at the screen's right edge: the card goes left of the row, the slot with it.
    @Test func atTheScreensRightEdgeTheCardGoesLeftAndKeepsTheSlot() {
        let right = CGRect(x: 1200, y: 600, width: 232, height: 32)
        let g = HoverCardEscapeGeometry(anchor: right, cardSize: size, visible: screen)
        #expect(g.isLeading)
        #expect(g.card.maxX == right.minX)
        #expect(g.zone(at: CGPoint(x: right.minX - 4, y: right.maxY - 2)) == .escape)
        #expect(g.zone(at: CGPoint(x: right.minX - 4, y: right.minY + 2)) == .card)
    }

    /// The touching edge stays on a device pixel toward the row at every scale: no seam the
    /// pointer could fall through on the path into the card.
    @Test(arguments: [1, 2, 3] as [CGFloat])
    func theTouchingEdgeSnapsIntoTheRow(scale: CGFloat) {
        let fractional = CGRect(x: 8.3, y: 600.3, width: 224.1, height: 31.7)
        let g = HoverCardEscapeGeometry(anchor: fractional, cardSize: size, visible: screen, scale: scale)
        let gap = g.card.minX - fractional.maxX
        #expect(gap <= 0.001 && gap > -1 / scale - 0.001, "@\(scale)x: \(gap) pt")
    }
}
