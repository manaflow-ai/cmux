import AppKit
import CmuxNextDesign
import Testing

/// The one placement every popup opened from a control uses (u2250): under the control, on
/// its edge, above it with no room below, on its other edge or slid back at the sides, inside
/// the window it opens over.
@MainActor @Suite struct PopupAnchorTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let size = CGSize(width: 240, height: 300)

    @Test func aTrailingAnchorPutsTheCardsTrailingEdgeOnTheControls() {
        let button = CGRect(x: 600, y: 500, width: 20, height: 20)
        let card = PopupAnchor(rect: button, edge: .trailing, gap: 2, margin: 4).cardFrame(size: size, visible: screen)
        #expect(card == CGRect(x: 380, y: 198, width: 240, height: 300))
    }

    @Test func aLeadingAnchorPutsTheCardsLeadingEdgeOnTheControls() {
        let name = CGRect(x: 40, y: 500, width: 100, height: 20)
        let card = PopupAnchor(rect: name, edge: .leading, gap: 2, margin: 4).cardFrame(size: size, visible: screen)
        #expect(card.minX == 40 && card.maxY == 498)
    }

    @Test func withNoRoomBelowTheCardOpensAbove() {
        let button = CGRect(x: 600, y: 100, width: 20, height: 20)
        let card = PopupAnchor(rect: button, edge: .trailing, gap: 2, margin: 4).cardFrame(size: size, visible: screen)
        #expect(card.minY == 122)
    }

    @Test func aCardThatWouldLeaveTheScreenFlipsOrSlidesBack() {
        let nearLeft = CGRect(x: 10, y: 500, width: 20, height: 20)
        let card = PopupAnchor(rect: nearLeft, edge: .trailing, gap: 2, margin: 4).cardFrame(size: size, visible: screen)
        #expect(card.minX == 10)
        let nearRight = CGRect(x: 980, y: 500, width: 20, height: 20)
        #expect(PopupAnchor(rect: nearRight, edge: .leading, gap: 2, margin: 4).cardFrame(size: size, visible: screen).maxX == 996)
    }

    /// A card opened in a window stays inside it: a trailing card with no room toward the
    /// leading side opens on the control's leading edge instead.
    @Test func aCardInAWindowFlipsToStayInsideIt() {
        let window = CGRect(x: 200, y: 100, width: 700, height: 600)
        let button = CGRect(x: 360, y: 500, width: 20, height: 20)
        let card = PopupAnchor(rect: button, edge: .trailing, gap: 2, margin: 4).cardFrame(size: size, visible: screen, window: window)
        #expect(card == CGRect(x: 360, y: 198, width: 240, height: 300))
        let nearRight = CGRect(x: 860, y: 500, width: 20, height: 20)
        #expect(PopupAnchor(rect: nearRight, edge: .leading, gap: 2, margin: 4).cardFrame(size: size, visible: screen, window: window).maxX == 880)
    }

    /// A card with no room under or over the control in its window slides up or down to stay
    /// inside it.
    @Test func aCardWithNoRoomAboveOrBelowStaysInsideTheWindow() {
        let window = CGRect(x: 200, y: 100, width: 700, height: 400)
        let button = CGRect(x: 600, y: 380, width: 20, height: 20)
        let card = PopupAnchor(rect: button, edge: .trailing, gap: 2, margin: 4).cardFrame(size: size, visible: screen, window: window)
        #expect(card.minY == 104, "card \(card) in window \(window)")
        #expect(window.contains(card), "card \(card) in window \(window)")
    }

    /// With no screen to read (`NSScreen.main` is nil on a fleet mini with no display), a card
    /// still keeps to the window it opens over: SidebarMenuAnchorTests' group editor hung 80 pt
    /// past the window's leading edge on the fleet (base red, 2026-10-21).
    @Test func aCardWithNoScreenStillKeepsToItsWindow() {
        let window = CGRect(x: 100, y: 200, width: 900, height: 600)
        let button = CGRect(x: 242, y: 700, width: 20, height: 20)
        let card = PopupAnchor(rect: button, edge: .trailing, gap: 2, margin: 4).cardFrame(size: size, visible: nil, window: window)
        #expect(window.contains(card), "card \(card) leaves the window \(window)")
        #expect(card.minX == 242, "card \(card) is not on the button's leading edge")
        // A window narrower than the card bounds nothing on that axis (as the screen would).
        let narrow = CGRect(x: 100, y: 200, width: 200, height: 600)
        let wide = PopupAnchor(rect: button, edge: .trailing, gap: 2, margin: 4).cardFrame(size: size, visible: nil, window: narrow)
        #expect(wide.maxX == 262 && wide.maxY == 698, "card \(wide) is not under the button's trailing edge")
        // With neither, the card is placed as anchored.
        #expect(PopupAnchor(rect: button, edge: .trailing, gap: 2, margin: 4).cardFrame(size: size, visible: nil).minX == 22)
    }

    /// A window too small for the card keeps the card on the screen instead.
    @Test func aCardWiderThanItsWindowKeepsToTheScreen() {
        let window = CGRect(x: 200, y: 100, width: 200, height: 600)
        let button = CGRect(x: 360, y: 500, width: 20, height: 20)
        let card = PopupAnchor(rect: button, edge: .trailing, gap: 2, margin: 4).cardFrame(size: size, visible: screen, window: window)
        #expect(card.maxX == 380)
    }

    @Test func aMenuOriginSitsUnderTheControlInFlippedAndUnflippedViews() {
        let button = CGRect(x: 300, y: 10, width: 20, height: 20)
        let anchor = PopupAnchor(rect: button, edge: .trailing, gap: 2, margin: 4)
        #expect(anchor.menuOrigin(size: size, flipped: true) == NSPoint(x: 80, y: 32))
        #expect(anchor.menuOrigin(size: size, flipped: false) == NSPoint(x: 80, y: 8))
    }

    @Test func aPointAnchorOpensAtThePoint() {
        let card = PopupAnchor(point: CGPoint(x: 500, y: 600)).cardFrame(size: size, visible: screen)
        #expect(card.minX == 500 && card.maxY == 600)
    }
}
