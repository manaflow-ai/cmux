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

    /// Austin 2026-10-20 (screen recording, a window filling the screen under the menu bar): "The
    /// cards, when I hover on the tabs, are not connected to the tabs themselves." `rest` put the
    /// card on its tab, but the card's window is larger than the card (`windowMargin` on every
    /// side), so for a tab just under the menu bar the window's top reached into the menu bar and
    /// AppKit moved the whole window down below it: the card hung a toolbar's height under its tab.
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    @Test(.enabled("the card's window is placed on a screen") { await Self.hasDisplay() })
    func aTabUnderTheMenuBarKeepsItsCardOnTheTab() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        // The menu bar band (or the top of a screen without one, when `visibleFrame` ends there).
        let top = screen.visibleFrame.maxY
        let parent = NSWindow(contentRect: NSRect(x: screen.frame.minX + 100, y: top - 400, width: 800, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFrontRegardless()
        let panel = HoverCardPanel()
        defer {
            panel.orderOut(nil)
            parent.close()
        }
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            body.widthAnchor.constraint(equalToConstant: Self.size.width),
            body.heightAnchor.constraint(equalToConstant: Self.size.height),
        ])
        // A tab in the window's top row, flush with the menu bar.
        let tab = CGRect(x: parent.frame.minX + 300, y: top - 36, width: 140, height: 36)
        panel.present(body: body, anchor: tab, placement: .below, parent: parent, themeAnchor: nil, sliding: false,
                      applyTheme: {})
        // The window as placed (`cardFrame` is its frame less the clear band), not as `rest` asked for.
        let card = panel.cardFrame
        #expect(abs(card.maxY - tab.minY) < 0.5, "card top \(card.maxY), tab bottom \(tab.minY): a \(tab.minY - card.maxY) pt gap")
        #expect(abs(card.minX - tab.minX) < 0.5, "card leading \(card.minX), tab leading \(tab.minX)")
    }

    /// The card's window may reach past the screen's visible frame: only `rest` places the card.
    @Test(.enabled("the card's window is placed on a screen") { await Self.hasDisplay() })
    func theCardsWindowIsNotPushedOutOfTheMenuBar() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        let frame = CGRect(x: screen.frame.minX + 100, y: screen.visibleFrame.maxY - 200, width: 400, height: 300)
        #expect(HoverCardPanel().constrainFrameRect(frame, to: screen) == frame)
    }
}
