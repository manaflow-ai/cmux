import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// cx-pd83 (nxdog89-v1): the browser import card ("Import bookmarks, history and passwords from
/// Google Chrome") stayed at the bottom of the pane after Cmd-T showed a New Tab page in it. The
/// card floats on the window's overlay host, not in the browser's views, so it must leave the
/// screen with its tab and come back when the tab shows again. Runs a real pane and a real WebKit
/// browser tab in a window, as the app shows them.
@MainActor @Suite(.serialized) struct BrowserImportCardTabSwitchTests {
    /// A tab that draws nothing until it paints, as the New Tab page (an agent page) does.
    final class UnpaintedPage: NSView, PaneFirstPaintGated {
        private var painted = false
        private var waiting: [() -> Void] = []
        var awaitsFirstPaint: Bool { !painted }
        func whenFirstPainted(_ body: @escaping () -> Void) {
            if painted { body() } else { waiting.append(body) }
        }

        func paint() {
            painted = true
            let callbacks = waiting
            waiting = []
            callbacks.forEach { $0() }
        }
    }

    struct Pane {
        let window: NSWindow
        let pane: PaneContentView
        let chrome: BrowserChromeView
        let page: WebKitTab

        init() {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("browser"), title: "Example")]),
                                   reveal: LaunchReveal(deadline: .zero))
            // The tab bar above the toolbar (the default): no header band, so a switch to a page
            // that has not painted holds the browser on screen (`PaneContentView.show`).
            pane.barOrder = .aboveToolbar
            pane.frame = window.contentLayoutRect
            window.contentView = pane
            window.orderFrontRegardless()
            page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
            chrome = BrowserChromeView(tab: page)
            pane.show(chrome)
            pane.layoutSubtreeIfNeeded()
        }

        /// The card the browser offers now, as the import offer service shows it.
        func offer() -> NSView? {
            let offer = BrowserCookieImportOffer(icons: [], title: "Import bookmarks, history and passwords from Google Chrome",
                                                 detail: "", importTitle: "Import…", notNowTitle: "Not Now")
            chrome.showCookieImportOffer(offer) { _ in }
            pane.layoutSubtreeIfNeeded()
            return chrome.currentCookieImportCard
        }

        /// Whether `card` is on screen: presented on this window's overlay host.
        func shows(_ card: NSView?) -> Bool {
            card?.window?.parent === window
        }

        func tearDown() {
            chrome.hideCookieImportOffer()
            window.orderOut(nil)
            window.close()
            page.close()
        }
    }

    @Test func theCardLeavesWithItsTabAndComesBackWithIt() throws {
        let tab = Pane()
        defer { tab.tearDown() }
        let card = try #require(tab.offer())
        #expect(tab.shows(card), "the card shows over its browser tab")

        let other = NSView()
        tab.pane.show(other)
        tab.pane.layoutSubtreeIfNeeded()
        #expect(!tab.shows(card), "another tab of the pane shows: the card is not over it")

        tab.pane.show(tab.chrome)
        tab.pane.layoutSubtreeIfNeeded()
        #expect(tab.shows(card), "its tab shows again, and so does the card")
    }

    /// Cmd-T: the New Tab page draws nothing until it paints, so the browser stays on screen
    /// until then (the pane's paint hold). Once the page shows, the card is gone with the browser.
    @Test func cmdTsNewTabPageShowsWithoutTheCard() throws {
        let tab = Pane()
        defer { tab.tearDown() }
        let card = try #require(tab.offer())
        #expect(tab.shows(card), "the card shows over its browser tab")
        let page = UnpaintedPage()
        tab.pane.show(page)
        tab.pane.layoutSubtreeIfNeeded()
        #expect(!tab.chrome.isHidden, "the browser stays on screen until the page paints")
        #expect(tab.shows(card), "and its card with it")
        page.paint()
        tab.pane.layoutSubtreeIfNeeded()
        #expect(tab.chrome.isHidden, "the browser is parked once the page painted")
        #expect(!tab.shows(card), "the New Tab page shows: the card is not over it")
    }

    /// The offer arrives while the New Tab page is about to show (the browsers are found off the
    /// main thread, so the card can come in the middle of Cmd-T).
    @Test func aCardOfferedDuringTheSwitchStaysOffTheNewTabPage() throws {
        let tab = Pane()
        defer { tab.tearDown() }
        let page = UnpaintedPage()
        tab.pane.show(page)
        tab.pane.layoutSubtreeIfNeeded()
        let card = try #require(tab.offer())
        #expect(tab.shows(card), "the browser is still on screen under the hold, and so is its card")
        page.paint()
        tab.pane.layoutSubtreeIfNeeded()
        #expect(!tab.shows(card), "the New Tab page shows: the card is not over it")
    }
}
