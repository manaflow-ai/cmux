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

    @Test func aChoiceInASubmenuOfThePagesContextMenuIsAUserActivation() throws {
        let web = PageWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        web.willOpenMenu(menu, with: try Self.rightClick())
        let parent = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let target = Target()
        submenu.addItem(Self.item(target))
        parent.submenu = submenu
        menu.addItem(parent)
        submenu.performActionForItem(at: 0)
        #expect(target.runs == 1)
        #expect(web.hasRecentUserGesture())
    }

    /// A pooled view rebound to another page (or parked for the next claim) starts with no
    /// activation: the new document cannot use a click the person made in the old one.
    @Test func aRetargetedPooledViewForgetsTheOldPagesActivation() throws {
        let host = try #require(PageWebView(pooledHost: .settings))
        defer { host.close() }
        let web = try #require(host.webKitView as? PageWKWebView)
        web.noteUserEvent(try Self.rightClick())
        #expect(host.router.hasUserGesture?() == true)
        #expect(host.retarget(descriptor: .history, routes: []))
        #expect(!web.hasRecentUserGesture())
        #expect(host.router.hasUserGesture?() == false)
    }

    @Test func aPooledViewParkedForTheNextClaimForgetsTheActivation() async throws {
        let host = try #require(PageWebView(pooledHost: .settings))
        defer { host.close() }
        let web = try #require(host.webKitView as? PageWKWebView)
        web.noteUserEvent(try Self.rightClick())
        await host.resetPooledPage()
        #expect(!web.hasRecentUserGesture())
    }
}
