import CoreGraphics
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// A sidebar row's hover card stays inside its window (Lawrence 2026-10-22: "If the card can spill
/// below the window at the bottom mark, add a window clamp"). The card only stayed on the visible
/// screen, so in a window that ends above the screen's bottom, the bottom row's card (a thin
/// rail's last mark, or the list's last row) hung below the window. The rule is still the one row
/// rule (`HoverCardEscapeGeometry`, `.besideRow`): top on the row's top, flush with the sidebar edge,
/// moved up only as far as the window needs.
@MainActor @Suite struct HoverCardWindowClampTests {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
    /// A window whose bottom edge is 300 pt above the screen's bottom (y up).
    private let window = CGRect(x: 100, y: 300, width: 900, height: 500)
    private let size = CGSize(width: 180, height: 30)
    private let margin: CGFloat = 8

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
        #expect(card.minX - row.maxX == 0, "the card is not flush with the sidebar edge")
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
        #expect(card.minX - row.maxX == 0, "the card's near edge is not flush with the sidebar edge")
        #expect(card.maxY == row.maxY, "still top-aligned with its row")
    }

    @Test func theTrackedGeometryMatchesTheRest() {
        // The panel keeps the card's geometry for its hover zones; it must be the card on screen.
        let row = CGRect(x: window.minX, y: window.minY + 10, width: 6, height: 6)
        let room = HoverCardEscapeGeometry.room(visible: visible, window: window, margin: margin)
        let geometry = HoverCardEscapeGeometry(anchor: row, cardSize: size, visible: room, scale: 2)
        #expect(geometry.card == rest(row, window: window))
    }
}


/// The What's New popover uses `.beside`, whose vertical clamp must honor the parent window
/// while still respecting the visible screen when the window is partly off-screen.
@MainActor struct HoverCardBesideWindowClampTests {
    private static let margin: CGFloat = 8
    private static let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private static let visible = CGRect(x: 0, y: 0, width: 1512, height: 945)
    private static let window = CGRect(x: 100, y: 200, width: 1100, height: 720)
    private static let popover = CGSize(width: 340, height: 432)
    private static let updateCard = CGRect(x: 110, y: 212, width: 216, height: 120)

    private static func card(_ anchor: CGRect, size: CGSize = popover, window: CGRect? = window) -> CGRect {
        let rest = HoverCardPanel.rest(for: .beside, anchor: anchor, size: size, screen: screen, visible: visible,
                                       window: window, margin: margin, scale: 2)
        #expect(rest.placement == .beside)
        return CGRect(origin: rest.origin, size: size)
    }

    @Test func thePopoverBesideTheUpdateCardStaysInTheWindow() {
        let card = Self.card(Self.updateCard)
        #expect(card.minY >= Self.window.minY + Self.margin)
        #expect(card.maxY <= Self.window.maxY - Self.margin)
        #expect(card.minX > Self.updateCard.maxX)
    }

    @Test func aCardThatFitsKeepsItsTopOnTheTarget() {
        let row = CGRect(x: 110, y: 700, width: 216, height: 32)
        let card = Self.card(row, size: CGSize(width: 280, height: 160))
        #expect(card.maxY == row.maxY)
        #expect(card.minX == row.maxX + HoverCardEscapeGeometry.edgeGap(scale: 2))
    }

    @Test func aCardTallerThanTheWindowKeepsItsTopInIt() {
        let short = CGRect(x: 100, y: 200, width: 1100, height: 300)
        let anchor = CGRect(x: 110, y: 212, width: 216, height: 120)
        let card = Self.card(anchor, window: short)
        #expect(card.maxY == short.maxY - Self.margin)
        #expect(card.minY >= Self.visible.minY + Self.margin)
    }

    @Test func withoutAWindowTheScreenAloneClampsTheCard() {
        let anchor = CGRect(x: 110, y: 40, width: 216, height: 120)
        let card = Self.card(anchor, window: nil)
        #expect(card.minY == Self.visible.minY + Self.margin)
    }

    @Test func aWindowPartlyOffTheScreenClampsToTheOverlap() {
        let low = CGRect(x: 100, y: -400, width: 1100, height: 720)
        let anchor = CGRect(x: 110, y: 20, width: 216, height: 120)
        let card = Self.card(anchor, size: CGSize(width: 340, height: 200), window: low)
        #expect(card.minY >= Self.visible.minY + Self.margin)
        #expect(card.maxY <= low.maxY - Self.margin)
    }

    @Test func aTallCardOverAWindowMostlyBelowTheScreenStaysOnTheScreen() {
        let low = CGRect(x: 100, y: -400, width: 1100, height: 720)
        let anchor = CGRect(x: 110, y: 20, width: 216, height: 120)
        let card = Self.card(anchor, window: low)
        #expect(card.minY == Self.visible.minY + Self.margin)
        #expect(card.maxY == Self.visible.minY + Self.margin + Self.popover.height)
    }

    @Test func aTallCardOverAWindowMostlyAboveTheScreenKeepsItsTopInTheWindow() {
        let high = CGRect(x: 100, y: 700, width: 1100, height: 720)
        let anchor = CGRect(x: 110, y: 820, width: 216, height: 120)
        let card = Self.card(anchor, window: high)
        #expect(card.maxY == Self.screen.maxY - Self.margin)
        #expect(card.minY >= Self.visible.minY + Self.margin)
    }

    @Test func aCardTallerThanTheScreenSitsOnItsBottom() {
        let low = CGRect(x: 100, y: -400, width: 1100, height: 720)
        let anchor = CGRect(x: 110, y: 20, width: 216, height: 120)
        let card = Self.card(anchor, size: CGSize(width: 340, height: 950), window: low)
        #expect(card.minY == Self.visible.minY + Self.margin)
    }
}
