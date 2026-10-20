import AppKit
import CmuxNextDesign
import Testing

/// The one placement every popup opened from a control uses (u2250): under the control, on
/// its edge, above it with no room below, back on screen at the sides.
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

    @Test func aCardThatWouldLeaveTheScreenSlidesBack() {
        let nearLeft = CGRect(x: 10, y: 500, width: 20, height: 20)
        let card = PopupAnchor(rect: nearLeft, edge: .trailing, gap: 2, margin: 4).cardFrame(size: size, visible: screen)
        #expect(card.minX == 4)
        let nearRight = CGRect(x: 980, y: 500, width: 20, height: 20)
        #expect(PopupAnchor(rect: nearRight, edge: .leading, gap: 2, margin: 4).cardFrame(size: size, visible: screen).maxX == 996)
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
