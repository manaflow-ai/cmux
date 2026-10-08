import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextBrowser

/// cx-367y: the cookie import card is a small glass card at the bottom of
/// the page; each answer reaches the host once and closes it, and the
/// chrome reports each finished page load once so the host can offer it.
@MainActor
struct BrowserCookieImportCardTests {
    static func offer(icons: Int = 3) -> BrowserCookieImportOffer {
        BrowserCookieImportOffer(
            icons: (0..<icons).map { _ in NSImage(size: NSSize(width: 32, height: 32)) },
            title: "Stay signed in to your sites", detail: "Import cookies from your other browsers.",
            importTitle: "Import Cookies…", notNowTitle: "Not Now", neverTitle: "Don’t Show Again"
        )
    }

    private func chrome() -> BrowserChromeView {
        let tab = MockBrowserTab(configuration: BrowserTabConfiguration(), engineKind: .cef, completesNavigationsImmediately: true)
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        chrome.layoutSubtreeIfNeeded()
        return chrome
    }

    @Test func theCardShowsItsLinesOnGlassAtTheBottomOfThePage() throws {
        let chrome = chrome()
        chrome.showCookieImportOffer(Self.offer(icons: 5)) { _ in }
        chrome.layoutSubtreeIfNeeded()
        #expect(chrome.showsCookieImportOffer)
        let card = try #require(chrome.currentCookieImportCard)
        #expect(card.shownText == ["Stay signed in to your sites", "Import cookies from your other browsers.", "Don’t Show Again",
                                   "Not Now", "Import Cookies…"])
        #expect(card.shownIconCount == 3, "at most three browser icons")
        #expect(card.glass?.material == OverlayMaterial.current, "glass, or opaque under Reduce Transparency")
        #expect(card.frame.width <= BrowserMetrics.promptMaxWidth + 0.5)
        #expect(card.frame.minY >= 0 && card.frame.minY <= BrowserMetrics.overlayInset + 0.5, "it sits at the bottom of the page")
        #expect(abs(card.frame.midX - chrome.bounds.midX) <= 1, "centered on the page")
    }

    @Test func everyAnswerReachesTheHostOnceAndClosesTheCard() throws {
        let presses: [((BrowserCookieImportCard) -> NSButton, BrowserCookieImportChoice)] = [
            ({ $0.importButton }, .importCookies), ({ $0.notNowButton }, .notNow), ({ $0.neverButton }, .never),
        ]
        for (press, expected) in presses {
            let chrome = chrome()
            var answers: [BrowserCookieImportChoice] = []
            chrome.showCookieImportOffer(Self.offer()) { answers.append($0) }
            let card = try #require(chrome.currentCookieImportCard)
            press(card).performClick(nil)
            #expect(answers == [expected])
            #expect(!chrome.showsCookieImportOffer, "an answer closes the card")
        }
    }

    @Test func aSecondOfferReplacesTheFirst() {
        let chrome = chrome()
        chrome.showCookieImportOffer(Self.offer()) { _ in }
        chrome.showCookieImportOffer(Self.offer(icons: 1)) { _ in }
        #expect(chrome.subviews.compactMap { $0 as? BrowserCookieImportCard }.filter { !$0.isDismissing }.count == 1)
        #expect(chrome.currentCookieImportCard?.shownIconCount == 1)
        chrome.hideCookieImportOffer()
        #expect(!chrome.showsCookieImportOffer)
    }

    @Test func eachFinishedPageIsReportedOnce() async {
        let tab = MockBrowserTab(configuration: BrowserTabConfiguration(), engineKind: .cef, completesNavigationsImmediately: true)
        let chrome = BrowserChromeView(tab: tab)
        var finished: [String] = []
        chrome.onPageFinished = { finished.append($0.absoluteString) }
        tab.load(URL(string: "https://example.com/")!)
        for _ in 0..<20 { await Task.yield() }
        tab.reload()
        for _ in 0..<20 { await Task.yield() }
        tab.load(URL(string: "https://example.org/a")!)
        for _ in 0..<20 { await Task.yield() }
        #expect(finished == ["https://example.com/", "https://example.org/a"])
    }
}
