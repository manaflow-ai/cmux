import AppKit
import Foundation
import Testing
import WebKit
@testable import CmuxNextPages

/// cx-qoxe: the host, never page script, decides whether a page call follows the person's own
/// input. A choice in the native context menu over the page counts like a click or key, so a
/// menu item that asks the page to copy (Copy Message, a host-built Copy) may write the clipboard;
/// a choice in some other menu does not.
@MainActor
@Suite struct PageUserActivationTests {
    final class Target: NSObject {
        var runs = 0
        @objc func run() { runs += 1 }
    }

    private static func rightClick() throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private static func item(_ target: Target) -> NSMenuItem {
        let item = NSMenuItem(title: "Copy Message", action: #selector(Target.run), keyEquivalent: "")
        item.target = target
        return item
    }

    @Test func aChoiceInThePagesContextMenuIsAUserActivation() throws {
        let web = PageWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        #expect(!web.hasRecentUserGesture())
        let menu = NSMenu()
        web.willOpenMenu(menu, with: try Self.rightClick())
        // A host's own item, added after the desktop filter (the agent pane's menu editor).
        let target = Target()
        menu.addItem(Self.item(target))
        menu.performActionForItem(at: 0)
        #expect(target.runs == 1)
        #expect(web.hasRecentUserGesture())
    }

    @Test func aChoiceInAnotherMenuIsNotThisPagesActivation() throws {
        let web = PageWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.willOpenMenu(NSMenu(), with: try Self.rightClick())
        let other = NSMenu()
        let target = Target()
        other.addItem(Self.item(target))
        other.performActionForItem(at: 0)
        #expect(target.runs == 1)
        #expect(!web.hasRecentUserGesture())
    }
}
