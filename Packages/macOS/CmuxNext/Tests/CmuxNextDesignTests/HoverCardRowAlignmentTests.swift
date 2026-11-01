import CoreGraphics
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Leo 2026-10-21: "WHY HAS IT NOT BEEN ALIGNED". A sidebar row's hover card sat with its top on
/// the row's middle (#22473), so it never lined up with the row it describes. It now sits beside
/// the sidebar with its top on the row's top, flush with the sidebar's edge, as Chrome's and Arc's tab
/// cards do, follows the row from row to row, and stays inside the screen's visible frame.
@MainActor @Suite struct HoverCardRowAlignmentTests {
    /// A 32 pt sidebar row on a 1440 x 900 screen (y up), and a 280 x 160 card.
    private let row = CGRect(x: 8, y: 600, width: 224, height: 32)
    private let size = CGSize(width: 280, height: 160)
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let margin: CGFloat = 8
    /// Workspace row cards touch the sidebar edge; non-sidebar `.beside` cards keep their own gap.
    private let gap: CGFloat = 0

    /// The card's frame at rest beside `anchor`, as the panel places a workspace card.
    private func card(for anchor: CGRect, visible: CGRect? = nil, scale: CGFloat = 2) -> CGRect {
        let rest = HoverCardPanel.rest(for: .besideRow, anchor: anchor, size: size, screen: screen, visible: visible ?? screen,
                                       window: nil, margin: margin, scale: scale)
        return CGRect(origin: rest.origin, size: size)
    }

    @Test func theDefaultLinesTheCardUpWithTheRowsTop() {
        #expect(HoverCardEscapeGeometry.escapeSlotTunable.defaultValue == false)
        #expect(HoverCardEscapeGeometry.currentAlignment == .top)
    }

    @Test func theCardsTopIsTheRowsTopBesideTheSidebar() {
        let card = card(for: row)
        #expect(card.maxY == row.maxY, "the card's top \(card.maxY) is not the row's top \(row.maxY)")
        #expect(card.minX == row.maxX + gap, "the card sits \(card.minX - row.maxX) pt from the row")
    }

    @Test func theGeometryHasNoEscapeSlotWhenTopAligned() {
        let g = HoverCardEscapeGeometry(anchor: row, cardSize: size, visible: screen)
        #expect(g.card == CGRect(x: row.maxX + gap, y: row.maxY - size.height, width: size.width, height: size.height))
        #expect(!g.isLeading)
        #expect(g.escapeSlot == .zero)
        #expect(g.gapStrip == .zero)
        // Right of the row's upper half is the card now, not an empty slot.
        #expect(g.zone(at: CGPoint(x: row.maxX + gap + 4, y: row.maxY - 3)) == .card)
    }

    /// The hover moves down the list: the card's top goes to each row's top in turn.
    @Test func theCardFollowsTheRowFromRowToRow() {
        for offset in [0, -32, -64, -200] as [CGFloat] {
            let next = row.offsetBy(dx: 0, dy: offset)
            let card = card(for: next)
            #expect(card.maxY == next.maxY, "row at \(next.minY): the card's top \(card.maxY) is not the row's top \(next.maxY)")
            #expect(card.minX == next.maxX + gap)
        }
    }

    /// Near the screen's bottom the card is clamped up into the visible frame, still beside its row.
    @Test func nearTheScreensBottomTheCardIsClampedUpBesideTheRow() {
        let low = CGRect(x: 8, y: 40, width: 224, height: 32)
        let card = card(for: low)
        #expect(card.minY == screen.minY + margin, "the card's bottom \(card.minY) is not on the visible frame's edge")
        #expect(card.minY <= low.minY && card.maxY >= low.maxY, "the card \(card) no longer spans its row \(low)")
        #expect(card.minX == low.maxX + gap)
    }

    /// A row whose top is above the visible frame (under the menu bar): the card's top stops at the frame.
    @Test func nearTheScreensTopTheCardStaysInTheVisibleFrame() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let high = CGRect(x: 8, y: 860, width: 224, height: 32)
        let card = card(for: high, visible: visible)
        #expect(card.maxY == visible.maxY - margin)
    }

    /// A sidebar at the screen's right edge: the card goes left of the row, still top-aligned.
    @Test func atTheScreensRightEdgeTheCardGoesLeftTopAligned() {
        let right = CGRect(x: 1200, y: 600, width: 232, height: 32)
        let g = HoverCardEscapeGeometry(anchor: right, cardSize: size, visible: screen.insetBy(dx: margin, dy: margin))
        #expect(g.isLeading)
        #expect(g.card.maxX == right.minX - gap)
        #expect(g.card.maxY == right.maxY)
    }

    /// A fractional row: the card's top lands on the device pixel nearest the row's top.
    @Test(arguments: [1, 2, 3] as [CGFloat])
    func theTopSnapsToTheNearestDevicePixel(scale: CGFloat) {
        let fractional = CGRect(x: 8.3, y: 600.3, width: 224.1, height: 31.7)
        let card = card(for: fractional, scale: scale)
        #expect(abs(card.maxY - fractional.maxY) <= 0.5 / scale + 0.001, "@\(scale)x: \(card.maxY - fractional.maxY) pt off the row's top")
        #expect(abs((card.maxY * scale).rounded() - card.maxY * scale) < 0.001, "@\(scale)x: the top is off the pixel grid")
    }

    /// The escape-slot layout stays reachable (Debug Settings): its top on the row's middle.
    @Test func theMiddleAlignmentKeepsTheEscapeSlotLayout() {
        let rest = HoverCardPanel.rest(for: .besideRow, anchor: row, size: size, screen: screen, visible: screen,
                                       window: nil, margin: margin, rowAlignment: .middle)
        #expect(rest.origin.y + size.height == row.midY)
    }
}
