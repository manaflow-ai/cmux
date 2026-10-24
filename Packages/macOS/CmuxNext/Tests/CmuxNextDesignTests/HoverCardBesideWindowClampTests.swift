import AppKit
@testable import CmuxNextDesign
import Testing

/// live-qa on nightly 3a63d6d, a 1100x720 window: the What's New popover beside the Update Ready
/// card at the sidebar's foot ran off the window's bottom and covered the composer's "+". A
/// `.beside` card (that popover, a group header's card, a PR badge's card) is top-aligned with its
/// target, so a target low in the window pushed it out of the window's bottom; the clamp kept it only
/// on the screen. It now stays inside the parent window too, and a card taller than the window's part
/// of the screen keeps its top in that part, unless that would push it off the screen's bottom: the
/// screen wins.
@MainActor struct HoverCardBesideWindowClampTests {
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

    private static func card(_ anchor: CGRect, size: CGSize = popover, window: CGRect? = window) -> CGRect {
        let rest = HoverCardPanel.rest(for: .beside, anchor: anchor, size: size, screen: screen, visible: visible,
                                       window: window, margin: margin, scale: 2)
        #expect(rest.placement == .beside)
        return CGRect(origin: rest.origin, size: size)
    }

    /// The popover beside the Update Ready card stays inside the window, its margin clear of the edge.
    @Test func thePopoverBesideTheUpdateCardStaysInTheWindow() {
        let card = Self.card(Self.updateCard)
        #expect(card.minY >= Self.window.minY + Self.margin,
                "the popover's bottom \(card.minY) is below the window's bottom \(Self.window.minY)")
        #expect(card.maxY <= Self.window.maxY - Self.margin, "the popover's top \(card.maxY) is above the window")
        #expect(card.minX > Self.updateCard.maxX, "the popover covers the card it describes")
    }

    /// A card that fits keeps its top on its target's top, as before.
    @Test func aCardThatFitsKeepsItsTopOnTheTarget() {
        let row = CGRect(x: 110, y: 700, width: 216, height: 32)
        let card = Self.card(row, size: CGSize(width: 280, height: 160))
        #expect(card.maxY == row.maxY)
        #expect(card.minX == row.maxX + HoverCardEscapeGeometry.rowGap)
    }

    /// A card taller than the window keeps its top in the window (and its bottom runs out instead).
    @Test func aCardTallerThanTheWindowKeepsItsTopInIt() {
        let short = CGRect(x: 100, y: 200, width: 1100, height: 300)
        let anchor = CGRect(x: 110, y: 212, width: 216, height: 120)
        let card = Self.card(anchor, window: short)
        #expect(card.maxY == short.maxY - Self.margin, "the tall card's top \(card.maxY), the window's top \(short.maxY)")
        #expect(card.minY >= Self.visible.minY + Self.margin, "the tall card runs off the screen")
    }

    /// With no parent window the card is clamped to the screen only, as before.
    @Test func withoutAWindowTheScreenAloneClampsTheCard() {
        let anchor = CGRect(x: 110, y: 40, width: 216, height: 120)
        let card = Self.card(anchor, window: nil)
        #expect(card.minY == Self.visible.minY + Self.margin)
    }

    /// A window mostly off the screen: the card stays where both overlap.
    @Test func aWindowPartlyOffTheScreenClampsToTheOverlap() {
        let low = CGRect(x: 100, y: -400, width: 1100, height: 720)
        let anchor = CGRect(x: 110, y: 20, width: 216, height: 120)
        let card = Self.card(anchor, size: CGSize(width: 340, height: 200), window: low)
        #expect(card.minY >= Self.visible.minY + Self.margin)
        #expect(card.maxY <= low.maxY - Self.margin)
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

    /// A card taller than the screen itself (950 pt, over the window mostly below the screen) sits on
    /// the screen's bottom and runs out of its top, never off its bottom.
    @Test func aCardTallerThanTheScreenSitsOnItsBottom() {
        let low = CGRect(x: 100, y: -400, width: 1100, height: 720)
        let anchor = CGRect(x: 110, y: 20, width: 216, height: 120)
        let card = Self.card(anchor, size: CGSize(width: 340, height: 950), window: low)
        #expect(card.minY == Self.visible.minY + Self.margin, "the card's bottom \(card.minY) is off the screen")
    }
}
