import AppKit
@testable import CmuxNextPages
import Testing

/// A choice in a page's own context menu is the person's gesture (`PageWKWebView.menuWillSendAction`):
/// AppKit posts `NSMenu.willSendActionNotification` on main before it sends the item's action, and the
/// view's observer (a `MainActorObservation`) notes the activation inline, so the page call the item leads
/// to (a host-built Copy) sees a recent gesture. A choice in any other menu is not this view's gesture.
@MainActor
struct PageMenuChoiceGestureTests {
    private static func rightClick() throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test func aChoiceInTheViewsOwnMenuIsAGesture() throws {
        let web = PageWKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: .init())
        let menu = NSMenu()
        web.willOpenMenu(menu, with: try Self.rightClick())
        #expect(!web.hasRecentUserGesture())
        NotificationCenter.default.post(name: NSMenu.willSendActionNotification, object: menu)
        #expect(web.hasRecentUserGesture())
    }

    @Test func aChoiceInASubmenuOfTheViewsMenuIsAGesture() throws {
        let web = PageWKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: .init())
        let menu = NSMenu()
        let submenu = NSMenu()
        let item = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopy")
        item.submenu = submenu
        menu.addItem(item)
        web.willOpenMenu(menu, with: try Self.rightClick())
        NotificationCenter.default.post(name: NSMenu.willSendActionNotification, object: submenu)
        #expect(web.hasRecentUserGesture())
    }

    @Test func aChoiceInAnotherMenuIsNoGesture() throws {
        let web = PageWKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: .init())
        web.willOpenMenu(NSMenu(), with: try Self.rightClick())
        NotificationCenter.default.post(name: NSMenu.willSendActionNotification, object: NSMenu())
        #expect(!web.hasRecentUserGesture())
    }
}
