import AppKit
import CmuxNextIcons
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// Every Chromium tab shows the Extensions (puzzle) button, as Chrome does, extensions installed
/// or pinned or not (Lawrence 2026-10-18, on the Home workspace's browser tab: "we need to show
/// extensions there by default, like the Extensions three-dot button, the Extensions button, and
/// all the pinned extensions"). Before, the button showed only while an extension was pinned
/// (cx-d0d.81) and the Extensions menu hid in More.
@MainActor @Suite(.closesItsWindows) struct BrowserToolbarExtensionsButtonTests {
    private func chromiumTab(_ actions: [CEFExtensionAction] = []) -> MockBrowserTab {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        tab.showsExtensionToolbar = true
        tab.extensionActions = actions
        return tab
    }

    private func report(_ tab: MockBrowserTab) -> BrowserToolbarReport {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = window.contentLayoutRect
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        return chrome.toolbarReport
    }

    @Test func aChromiumTabWithNothingPinnedShowsTheExtensionsButton() {
        let report = report(chromiumTab([CEFExtensionAction(id: "onepassword", name: "1Password", title: "1Password")]))
        #expect(report.showsExtensionsButton)
        #expect(report.visibleActions.isEmpty)
    }

    @Test func aChromiumTabWithNoExtensionsStillShowsTheExtensionsButton() {
        #expect(report(chromiumTab()).showsExtensionsButton)
    }

    @Test func pinnedExtensionsShowBesideTheExtensionsButton() {
        let report = report(chromiumTab([
            CEFExtensionAction(id: "onepassword", name: "1Password", title: "1Password", isPinned: true),
            CEFExtensionAction(id: "ublock", name: "uBlock", title: "uBlock"),
        ]))
        #expect(report.showsExtensionsButton)
        #expect(report.visibleActions == ["onepassword"])
    }

    @Test func aTabWithoutTheExtensionToolbarShowsNoButton() {
        let tab = chromiumTab()
        tab.showsExtensionToolbar = false
        #expect(!report(tab).showsExtensionsButton)
    }

    /// The Downloads and Extensions buttons draw Chrome's own glyphs (Lawrence 2026-10-18: "for
    /// downloads and extensions icons use same icons if possible"), and the bundled pack has both.
    @Test func downloadsAndExtensionsDrawChromesGlyphs() {
        let facts = BrowserToolbarFacts(engine: .cef, hostsDevTools: true)
        #expect(BrowserToolbarPolicy.state(.downloads, facts).icon == .browserToolbarDownloads)
        #expect(IconPack.bundled.drawing(for: .browserToolbarDownloads) != nil)
        #expect(IconPack.bundled.drawing(for: .browserToolbarExtensions) != nil)
    }
}
