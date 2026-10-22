import CoreGraphics
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

<<<<<<< HEAD
/// A sidebar row's hover card stays inside its window (Lawrence 2026-10-22: "If the card can spill
/// below the window at the bottom mark, add a window clamp"). The card only stayed on the visible
/// screen, so in a window that ends above the screen's bottom, the bottom row's card (a thin
/// rail's last mark, or the list's last row) hung below the window. The rule is still the one row
/// rule (`HoverCardEscapeGeometry`, `.besideRow`): top on the row's top, 1 px off the sidebar edge,
/// moved up only as far as the window needs.
@MainActor @Suite struct HoverCardWindowClampTests {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
    /// A window whose bottom edge is 300 pt above the screen's bottom (y up).
    private let window = CGRect(x: 100, y: 300, width: 900, height: 500)
    private let size = CGSize(width: 180, height: 30)
    private let margin: CGFloat = 8
=======
/// live-qa on nightly 3a63d6d, a 1100x720 window: the What's New popover beside the Update Ready
/// card at the sidebar's foot ran off the window's bottom and covered the composer's "+". A
/// `.beside` card (that popover, a group header's card, a PR badge's card) is top-aligned with its
/// target, so a target low in the window pushed it out of the window's bottom; the clamp kept it only
/// on the screen. It now stays inside the parent window too, and a card taller than the window's part
/// of the screen keeps its top in that part, unless that would push it off the screen: the screen wins.
@MainActor struct HoverCardWindowClampTests {
    private static let margin: CGFloat = 8
    /// A 14-inch notch display: the menu bar band is 37 pt.
    private static let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private static let visible = CGRect(x: 0, y: 0, width: 1512, height: 945)
    /// A 1100x720 window, 200 pt above the screen's bottom.
    private static let window = CGRect(x: 100, y: 200, width: 1100, height: 720)
    /// The What's New popover: 340 wide, at most 60% of the window's height.
    private static let popover = CGSize(width: 340, height: 432)
    /// The Update Ready card at the sidebar's foot, 12 pt above the window's bottom.
    private static let updateCard = CGRect(x: 110, y: 212, width: 216, height: 120)
>>>>>>> 6717dc054f0 (cmux NEXT hover cards: the screen wins over the window for a tall beside card)

    private func rest(_ anchor: CGRect, window: CGRect?) -> CGRect {
        let rest = HoverCardPanel.rest(for: .besideRow, anchor: anchor, size: size, screen: screen, visible: visible,
                                       window: window, margin: margin, scale: 2)
        return CGRect(origin: rest.origin, size: size)
    }

    @Test func theBottomRowsCardStaysInsideTheWindow() {
        // A 6 pt rail's last mark, 10 pt above the window's bottom edge.
        let row = CGRect(x: window.minX, y: window.minY + 10, width: 6, height: 6)
        let card = rest(row, window: window)
        #expect(card.minY >= window.minY, "the card does not hang below the window")
        #expect(card.minX - row.maxX == 0.5, "still one device pixel off the sidebar edge")
        #expect(card.maxY > row.minY, "still beside its row")
    }

    @Test func aRowWithRoomKeepsItsTopOnTheRowsTop() {
        let row = CGRect(x: window.minX, y: window.maxY - 120, width: 6, height: 6)
        let card = rest(row, window: window)
        #expect(card.maxY == row.maxY)
    }

    /// The window clamp is only up and down: in a window no wider than its sidebar (the sidebar
    /// fills it), the card still goes beside the sidebar, past the window's right edge, and never
    /// over the rows it describes (SidebarHoverCardEscapeTests on a host with a screen).
    @Test func aSidebarThatFillsItsWindowKeepsItsCardBesideIt() {
        let narrow = CGRect(x: 200, y: 100, width: 240, height: 400)
        let row = CGRect(x: narrow.minX, y: narrow.maxY - 120, width: narrow.width, height: 28)
        let card = rest(row, window: narrow)
        #expect(card.minX - row.maxX == 0.5, "the card's near edge is one device pixel off the sidebar's edge, not over the rows")
        #expect(card.maxY == row.maxY, "still top-aligned with its row")
    }

    @Test func theTrackedGeometryMatchesTheRest() {
        // The panel keeps the card's geometry for its hover zones; it must be the card on screen.
        let row = CGRect(x: window.minX, y: window.minY + 10, width: 6, height: 6)
        let room = HoverCardEscapeGeometry.room(visible: visible, window: window, margin: margin)
        let geometry = HoverCardEscapeGeometry(anchor: row, cardSize: size, visible: room, scale: 2)
        #expect(geometry.card == rest(row, window: window))
    }

    /// A card taller than the part of a window mostly below the screen (the window's inset part runs
    /// y=8...312, 304 pt, for a 432 pt card): no place keeps it both on the screen and under the
    /// window's top, and the screen wins. It sits on the screen's bottom, and its top rises past the
    /// window's by the 128 pt it must, no further.
    @Test func aTallCardOverAWindowMostlyBelowTheScreenStaysOnTheScreen() {
        let low = CGRect(x: 100, y: -400, width: 1100, height: 720)
        let anchor = CGRect(x: 110, y: 20, width: 216, height: 120)
        let card = Self.card(anchor, window: low)
        #expect(card.minY == Self.visible.minY + Self.margin, "the tall card's bottom \(card.minY) is off the screen")
        #expect(card.maxY == Self.visible.minY + Self.margin + Self.popover.height,
                "the tall card's top \(card.maxY) rises past the window's further than the screen needs")
    }

    /// The mirror, a window mostly above the screen: the window's part of the screen is shorter than
    /// the card too, and the card keeps its top in that part (in the menu bar band the window covers)
    /// and runs out of the window's bottom, still on the screen.
    @Test func aTallCardOverAWindowMostlyAboveTheScreenKeepsItsTopInTheWindow() {
        let high = CGRect(x: 100, y: 700, width: 1100, height: 720)
        let anchor = CGRect(x: 110, y: 820, width: 216, height: 120)
        let card = Self.card(anchor, window: high)
        #expect(card.maxY == Self.screen.maxY - Self.margin,
                "the tall card's top \(card.maxY) left the window's part of the screen")
        #expect(card.minY >= Self.visible.minY + Self.margin, "the tall card runs off the screen")
    }
}
