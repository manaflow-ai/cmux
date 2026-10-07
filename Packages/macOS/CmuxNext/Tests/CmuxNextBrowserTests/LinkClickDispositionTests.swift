import AppKit
import Testing
@testable import CmuxNextBrowser

/// Link clicks and the link context menu in WebKit tabs, as in Chrome and
/// Safari: Cmd-click and middle click open a background tab, Shift-Cmd-click
/// a foreground tab, Shift-click a new window, Option-click downloads.
/// The link menu's rows are the host's (`WebKitContextHit`), as in Chromium.
@MainActor
@Suite(.serialized)
struct LinkClickDispositionTests {
    @Test func modifiersPickWhereALinkOpens() {
        typealias A = WebKitTab.LinkClick
        #expect(WebKitTab.linkClick(flags: [], button: 0) == A.pageDefault)
        #expect(WebKitTab.linkClick(flags: [.command], button: 0) == A.open(.backgroundTab))
        #expect(WebKitTab.linkClick(flags: [], button: 2) == A.open(.backgroundTab))
        #expect(WebKitTab.linkClick(flags: [.command, .shift], button: 0) == A.open(.foregroundTab))
        #expect(WebKitTab.linkClick(flags: [.shift], button: 0) == A.open(.newWindow))
        #expect(WebKitTab.linkClick(flags: [.option], button: 0) == A.download)
    }

    /// A host that answers the link menu with one row.
    final class Host: BrowserTabDelegate {
        let row = NSMenuItem(title: "Open Link in New Tab", action: nil, keyEquivalent: "")
        var targets: [BrowserContextMenuTarget] = []
        func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
            guard case .contextMenu(let request) = intent else { return }
            targets.append(request.target)
            request.insertLeading?([row])
        }
    }

    static func webKitMenu() -> NSMenu {
        let menu = NSMenu()
        for id in ["WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierDownloadLinkedFile",
                   "WKMenuItemIdentifierCopyLink", "", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierLookUp", "",
                   "WKMenuItemIdentifierInspectElement"] {
            if id.isEmpty { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            menu.addItem(item)
        }
        return menu
    }

    /// The hit script's report turns WebKit's link rows into the host's
    /// rows (the same rows Chromium shows); WebKit's other rows stay.
    @Test func linkMenuRowsComeFromTheHost() throws {
        let tab = WebKitEngine().makeWebKitTab(profile: .default)
        let host = Host()
        tab.delegate = host
        let hit = BrowserContextMenuTarget(linkURL: URL(string: "https://example.com/a"), linkText: "A", selection: "A")
        tab.contextHit = (target: hit, at: ContinuousClock.now)
        let menu = Self.webKitMenu()
        try #require(tab.webView as? WebKitWebView).adjustContextMenu(menu)
        #expect(host.targets == [hit])
        let ids = menu.items.map { $0.isSeparatorItem ? "---" : ($0.identifier?.rawValue ?? $0.title) }
        #expect(ids == ["Open Link in New Tab", "---", "WKMenuItemIdentifierInspectElement"])
        #expect(tab.takeContextHit() == nil, "one menu per report")
    }

    /// Without a fresh report (a PDF, a click the script did not see) WebKit's
    /// own rows stay.
    @Test func aStaleHitKeepsWebKitsRows() throws {
        let tab = WebKitEngine().makeWebKitTab(profile: .default)
        let host = Host()
        tab.delegate = host
        tab.contextHit = (target: BrowserContextMenuTarget(linkURL: URL(string: "https://example.com/a")), at: ContinuousClock.now - .seconds(5))
        let menu = Self.webKitMenu()
        let before = menu.items.map(\.title)
        try #require(tab.webView as? WebKitWebView).adjustContextMenu(menu)
        #expect(host.targets.isEmpty)
        #expect(menu.items.map(\.title) == before)
    }
}
