import AppKit
@testable import CmuxNextDesign
import Testing

/// Leo 2026-10-20: the Chief Settings card hung off the leading edge of the "Chief" pill it opens
/// from, over the transcript, instead of sitting under the pill as an `NSPopover` does. A
/// `centered` popup is centered on its anchor, still kept on the screen.
@Suite struct PopupPlacementCenteredTests {
    static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func aCenteredPopupSitsCenteredUnderItsAnchor() {
        let pill = CGRect(x: 680, y: 800, width: 80, height: 24)
        let (frame, side) = PopupPlacement.frame(anchor: pill, size: CGSize(width: 320, height: 400), preferred: .below,
                                                 centered: true, screen: Self.screen)
        #expect(side == .below)
        #expect(frame.midX == pill.midX, "card \(frame) is not centered on the pill \(pill)")
        #expect(frame.maxY <= pill.minY)
    }

    @Test func aLeadingPopupStillStartsAtItsAnchorsLeadingEdge() {
        let pill = CGRect(x: 680, y: 800, width: 80, height: 24)
        let (frame, _) = PopupPlacement.frame(anchor: pill, size: CGSize(width: 320, height: 400), preferred: .below,
                                              screen: Self.screen)
        #expect(frame.minX == pill.minX)
    }

    /// A pill whose width is not a whole number (its title's) still gets a card exactly as wide as
    /// its content, within half a point of centered.
    @Test func aCenteredPopupKeepsItsWidthUnderAFractionalAnchor() {
        let pill = CGRect(x: 680.25, y: 800, width: 61.3, height: 24)
        let (frame, _) = PopupPlacement.frame(anchor: pill, size: CGSize(width: 320, height: 400), preferred: .below,
                                              centered: true, screen: Self.screen)
        #expect(frame.width == 320)
        #expect(abs(frame.midX - pill.midX) <= 0.5)
    }

    /// Near the screen's edge the centered card moves in to stay on the screen, past the margin.
    @Test func aCenteredPopupStaysOnTheScreen() {
        let pill = CGRect(x: 10, y: 800, width: 80, height: 24)
        let (frame, _) = PopupPlacement.frame(anchor: pill, size: CGSize(width: 320, height: 400), preferred: .below,
                                              centered: true, screen: Self.screen, margin: 6)
        #expect(frame.minX == 6)
    }

    @Test func aSubmenuOpensToTheRightWhenThereIsRoom() {
        let row = CGRect(x: 600, y: 500, width: 120, height: 28)
        let placed = PopupPlacement.sideBySideFrame(anchor: row, size: CGSize(width: 240, height: 300), screen: Self.screen)
        #expect(placed.side == .right)
        #expect(placed.frame.minX == row.maxX + 4)
        #expect(placed.frame.maxY == row.maxY)
    }

    @Test func aSubmenuFlipsToTheLeftAtTheScreenEdge() {
        let row = CGRect(x: 1300, y: 500, width: 90, height: 28)
        let placed = PopupPlacement.sideBySideFrame(anchor: row, size: CGSize(width: 240, height: 300), screen: Self.screen)
        #expect(placed.side == .left)
        #expect(placed.frame.maxX == row.minX - 4)
        #expect(placed.frame.maxX <= Self.screen.maxX - 6)
    }
}
