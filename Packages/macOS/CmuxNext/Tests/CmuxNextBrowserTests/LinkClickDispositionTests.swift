import AppKit
import Testing
@testable import CmuxNextBrowser

/// Link clicks and the link context menu in WebKit tabs, as in Chrome and
/// Safari: Cmd-click and middle click open a background tab, Shift-Cmd-click
/// a foreground tab, Shift-click a new window, Option-click downloads.
/// "Open Link in New Tab" opens a background tab; "Open Link in New Window"
/// opens a window.
@MainActor
@Suite(.serialized)
struct LinkClickDispositionTests {
    @Test func modifiersPickWhereALinkOpens() {
        typealias A = WebKitTab.LinkClick
        #expect(WebKitTab.linkClick(flags: [], button: 0) == A.navigate)
        #expect(WebKitTab.linkClick(flags: [.command], button: 0) == A.open(.backgroundTab))
        #expect(WebKitTab.linkClick(flags: [], button: 2) == A.open(.backgroundTab))
        #expect(WebKitTab.linkClick(flags: [.command, .shift], button: 0) == A.open(.foregroundTab))
        #expect(WebKitTab.linkClick(flags: [.shift], button: 0) == A.open(.newWindow))
        #expect(WebKitTab.linkClick(flags: [.option], button: 0) == A.download)
    }

    final class Probe: NSObject {
        var fired = 0
        @objc func open(_ sender: Any?) { fired += 1 }
    }

    /// WebKit's own "Open Link in New Window" item still runs (it creates the
    /// page with its opener); cmux records where the page goes first.
    @Test func linkMenuItemsOpenABackgroundTabAndANewWindow() throws {
        let tab = WebKitEngine().makeWebKitTab(BrowserTabConfiguration(profile: .default))
        let probe = Probe()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Open Link in New Window", action: #selector(Probe.open(_:)), keyEquivalent: "")
        item.target = probe
        item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
        menu.addItem(item)
        try #require(tab.webView as? WebKitWebView).adjustContextMenu(menu)

        let newTab = try #require(menu.items.first { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" })
        #expect(newTab.title == Strings.openLinkInNewTab)
        menu.performActionForItem(at: menu.index(of: newTab))
        #expect(probe.fired == 1)
        #expect(tab.takeContextMenuDisposition() == .backgroundTab)

        let newWindow = try #require(menu.items.first { $0.title == Strings.openLinkInNewWindow })
        menu.performActionForItem(at: menu.index(of: newWindow))
        #expect(probe.fired == 2)
        #expect(tab.takeContextMenuDisposition() == .newWindow)
        #expect(tab.takeContextMenuDisposition() == nil, "one page per pick")
    }
}
