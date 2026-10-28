import CoreGraphics
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

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
}
