import AppKit
@testable import CmuxNextDesign
import Testing

/// Lawrence 2026-10-20 (screenshot of a browser tab's card): "Tab cards are still disjoint from
/// the tab itself." The card sat below the browser toolbar and left of its tab: the screen clamp
/// kept it inside the screen's visible frame, which leaves out the menu bar and notch band where a
/// full-screen window's tabs sit, and a tab near the right edge pushed the card left instead of
/// lining it up with the tab. Like Chrome and Helium, a tab's card stays on its tab: its top on
/// the tab's bottom edge, its leading edge on the tab's (its trailing edge on the tab's when there
/// is no room to the right), and it flips above only when there is no room below.
@MainActor struct TabHoverCardAttachTests {
    private static let size = CGSize(width: 240, height: 180)
    private static let margin: CGFloat = 8
    /// A 14-inch notch display: the menu bar band is 37 pt.
    private static let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private static let visible = CGRect(x: 0, y: 0, width: 1512, height: 945)

    private static func rest(_ anchor: CGRect, placement: HoverCardPlacement = .below, window: CGRect = screen) -> HoverCardRest {
        HoverCardPanel.rest(for: placement, anchor: anchor, size: size, screen: screen, visible: visible, window: window,
                            margin: margin, scale: 2)
    }

    private static func card(_ rest: HoverCardRest) -> CGRect { CGRect(origin: rest.origin, size: size) }

    /// A full-screen window's tab in the menu bar band: the card still hangs from the tab.
    @Test func aFullScreenTabsCardHangsFromTheTab() {
        let tab = CGRect(x: 600, y: 982 - 6 - 28, width: 120, height: 28)
        let card = Self.card(Self.rest(tab))
        #expect(card.maxY == tab.minY, "card top \(card.maxY), tab bottom \(tab.minY): a \(tab.minY - card.maxY) pt gap")
        #expect(card.minX == tab.minX, "card leading \(card.minX), tab leading \(tab.minX)")
    }

    /// A tab near the screen's right edge: the card's trailing edge lines up with the tab's.
    @Test func aTabNearTheRightEdgeAlignsTheCardsTrailingEdge() {
        let tab = CGRect(x: 1380, y: 700, width: 100, height: 28)
        let card = Self.card(Self.rest(tab))
        #expect(card.maxX == tab.maxX, "card trailing \(card.maxX), tab trailing \(tab.maxX)")
        #expect(card.maxY == tab.minY)
    }

    /// The usual case is unchanged: leading edges aligned, no gap.
    @Test func aTabWithRoomGetsItsCardLeadingAlignedAndFlush() {
        let tab = CGRect(x: 300, y: 700, width: 140, height: 28)
        let rest = Self.rest(tab)
        #expect(rest.placement == .below)
        #expect(Self.card(rest).minX == tab.minX)
        #expect(Self.card(rest).maxY == tab.minY)
    }

    /// No room below (a short window low on the screen): the card flips above the tab, touching it.
    @Test func noRoomBelowFlipsTheCardAboveTheTab() {
        let tab = CGRect(x: 300, y: 60, width: 140, height: 28)
        let rest = Self.rest(tab)
        #expect(rest.placement == .above)
        #expect(Self.card(rest).minY == tab.maxY)
    }

    /// A bottom tab bar in a full-screen window: the card rests on the tab's top edge.
    @Test func aBottomTabBarsCardRestsOnTheTab() {
        let tab = CGRect(x: 300, y: 4, width: 140, height: 28)
        let card = Self.card(Self.rest(tab, placement: .above))
        #expect(card.minY == tab.maxY)
        #expect(card.minX == tab.minX)
    }
}
