import AppKit
import Testing
@testable import CmuxNextAgentPane

/// A message's More button (webviews MessageActions.tsx MessageMore) reports the message as its
/// right-click does, plus the button's box (`popUp`): the pane opens the same menu under it.
@Suite
@MainActor
struct AgentPaneMoreMenuTests {
    static func titles(_ report: [String: Any]) -> [String] {
        let menu = NSMenu()
        AgentPaneContextMenu.rebuild(menu, target: AgentPaneMessageTarget(report: report), devTools: false,
                                     actions: .init(copy: { _ in }, fork: { _ in }))
        return menu.items.map(\.title)
    }

    @Test func aMorePressOpensTheRightClicksItemsUnderTheButton() throws {
        let rightClick: [String: Any] = ["text": "Done.", "markdown": "**Done.**", "forkSeq": 3, "links": ["https://cmux.dev"]]
        var more = rightClick
        more["popUp"] = ["left": 10, "top": 20, "right": 34, "bottom": 44]
        #expect(AgentPaneContextMenu.popUpAnchor(report: more) == CGRect(x: 10, y: 20, width: 24, height: 24))
        #expect(AgentPaneContextMenu.popUpAnchor(report: rightClick) == nil)
        #expect(Self.titles(more) == Self.titles(rightClick))
        #expect(Self.titles(more).contains(AgentPaneMenuStrings.copyAsPlainText))
    }

    static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    static let menu = CGSize(width: 220, height: 300)

    static func origin(_ button: CGRect, window: CGRect, menu: CGSize = menu) -> CGPoint {
        AgentPaneContextMenu.popUpOrigin(button: button, size: menu, visible: screen, window: window)
    }

    /// With room for the whole menu below in the window, it opens 2 pt under the button, as before.
    @Test func withRoomBelowTheMenuOpensUnderTheButton() {
        #expect(Self.origin(CGRect(x: 400, y: 600, width: 24, height: 24), window: Self.screen) == CGPoint(x: 400, y: 598))
    }

    /// The last reply's More, just over the composer: the menu does not fit below in the window
    /// (AppKit cut it to a scroll arrow), so it opens above the button, inside the window.
    @Test func overTheComposerTheMenuOpensAboveTheButton() {
        let window = CGRect(x: 100, y: 200, width: 900, height: 600)
        let origin = Self.origin(CGRect(x: 400, y: 330, width: 24, height: 24), window: window)
        #expect(origin == CGPoint(x: 400, y: 356 + 300))
        let frame = CGRect(x: origin.x, y: origin.y - Self.menu.height, width: Self.menu.width, height: Self.menu.height)
        #expect(window.contains(frame), "menu \(frame) in window \(window)")
    }

    /// In a window too short for either side the menu opens on the side with more room, past the
    /// window's edge but whole on the screen.
    @Test func withNoRoomOnEitherSideTheMenuTakesTheRoomierSide() {
        let window = CGRect(x: 100, y: 200, width: 900, height: 300)
        #expect(Self.origin(CGRect(x: 400, y: 260, width: 24, height: 24), window: window) == CGPoint(x: 400, y: 586))
        #expect(Self.origin(CGRect(x: 400, y: 420, width: 24, height: 24), window: window) == CGPoint(x: 400, y: 418))
    }

    /// A short window near the screen's top, room for the menu on neither side in it: below fits on
    /// the screen, so it opens there. Picked by the window's room it went up, past the window and the
    /// screen's top, and was pushed back down over its own button (680 to 900 over 670 to 694).
    @Test func withNoRoomInTheWindowTheMenuTakesTheSideThatFitsOnTheScreen() {
        let window = CGRect(x: 100, y: 500, width: 900, height: 380)
        let button = CGRect(x: 400, y: 670, width: 24, height: 24)
        let menu = CGSize(width: 220, height: 220)
        let origin = Self.origin(button, window: window, menu: menu)
        #expect(origin == CGPoint(x: 400, y: 668))
        let frame = CGRect(x: origin.x, y: origin.y - menu.height, width: menu.width, height: menu.height)
        #expect(!frame.intersects(button), "menu \(frame) over button \(button)")
        #expect(Self.screen.contains(frame))
    }

    /// A menu that would run past the screen on its side slides back onto it, so AppKit never
    /// shrinks it to a scroll arrow.
    @Test func theMenuStaysWholeOnTheScreen() {
        let tall = CGSize(width: 220, height: 500)
        let origin = Self.origin(CGRect(x: 400, y: 400, width: 24, height: 24), window: Self.screen, menu: tall)
        #expect(origin == CGPoint(x: 400, y: 900))
    }
}
