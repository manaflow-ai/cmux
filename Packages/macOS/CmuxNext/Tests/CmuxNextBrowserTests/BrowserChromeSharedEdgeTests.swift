import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// Review of #32909 step B (one chrome per pane): the edges of a shared chrome. A tab moved to another pane's chrome
/// leaves the first chrome with nothing of it and keeps what it showed; a closed tab's page is not held by the
/// chrome; a page that navigated while hidden shows design mode off; a cookie offer waits for its tab.
@MainActor @Suite(.serialized, .closesItsWindows) struct BrowserChromeSharedEdgeTests {
    static func tab(_ host: String) -> MockBrowserTab {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://\(host)/")))
        tab.load(URL(string: "https://\(host)/")!)
        return tab
    }

    static func window(_ chrome: BrowserChromeView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        chrome.frame = window.contentLayoutRect
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        return window
    }

    static func settle() async { for _ in 0..<8 { await Task.yield() } }

    /// A tab dragged to another pane: that pane's chrome takes it with what it showed, and the first chrome lets it go
    /// (no second render of it: one history visit per load, not two).
    @Test func aTabMovedToAnotherPanesChromeLeavesTheFirstChromeAndKeepsItsState() async {
        let t = Self.tab("t.example"), u = Self.tab("u.example")
        let stateT = BrowserChromeTabState(), stateU = BrowserChromeTabState()
        let paneA = BrowserPaneChrome(), paneB = BrowserPaneChrome()
        let chromeA = paneA.bind(t, state: stateT)
        let window = Self.window(chromeA)
        defer {
            window.close()
            paneA.drop()
            paneB.drop()
            t.close()
            u.close()
        }
        chromeA.addressBar.controller.send(.focusGained(.keyboard))
        chromeA.addressBar.controller.send(.fieldChanged(OmnibarInput.Field(text: "typed in A", selection: NSRange(location: 10, length: 0)), .insert))
        let chromeB = paneB.bind(t, state: stateT)
        let windowB = Self.window(chromeB)
        defer { windowB.close() }
        #expect(chromeA !== chromeB)
        #expect(chromeA.boundState == nil, "pane A's chrome no longer shows the moved tab")
        #expect(chromeA.tab !== t, "pane A's chrome no longer holds or watches the moved tab's page")
        #expect(t.contentView.superview === chromeB.contentContainer)
        #expect(chromeB.addressBar.displayedText == "typed in A", "the moved tab keeps the text left in its omnibar: \(chromeB.addressBar.displayedText)")
        paneA.bind(u, state: stateU)
        #expect(chromeA.tab === u)
    }

    /// The pane's shown tab closes: the chrome keeps nothing of it (its page is freed with its tab).
    @Test func aClosedTabsPageIsNotHeldByThePanesChrome() async {
        weak var closedPage: MockBrowserTab?
        let pane = BrowserPaneChrome()
        let other = Self.tab("other.example")
        defer {
            pane.drop()
            other.close()
        }
        autoreleasepool {
            let page = Self.tab("closed.example")
            closedPage = page
            let state = BrowserChromeTabState()
            pane.bind(page, state: state)
            BrowserTabRetirement(tab: page, state: state).retire()
        }
        await Self.settle()
        #expect(closedPage == nil, "the pane's chrome still holds the closed tab's page")
    }

    /// Design mode is per document: a tab that navigated while another tab showed comes back with it off.
    @Test func aPageThatNavigatedWhileHiddenShowsDesignModeOff() async {
        let t = Self.tab("t.example"), u = Self.tab("u.example")
        let stateT = BrowserChromeTabState(), stateU = BrowserChromeTabState()
        let pane = BrowserPaneChrome()
        let chrome = pane.bind(t, state: stateT)
        let window = Self.window(chrome)
        defer {
            window.close()
            pane.drop()
            t.close()
            u.close()
        }
        chrome.toolbarButtons.modes.designMode = true
        pane.bind(u, state: stateU)
        t.load(URL(string: "https://t.example/next")!)
        await Self.settle()
        pane.bind(t, state: stateT)
        await Self.settle()
        #expect(!chrome.toolbarButtons.modes.designMode, "design mode stayed on for a document that never had it")
    }

    /// The cookie import offer stays with its tab: a switch away and back shows it again (it shows once per launch).
    @Test func aCookieOfferComesBackWithItsTab() async {
        let t = Self.tab("t.example"), u = Self.tab("u.example")
        let stateT = BrowserChromeTabState(), stateU = BrowserChromeTabState()
        stateT.hasKeyboard = true  // the person is in tab T: its cookie offer may show
        let pane = BrowserPaneChrome()
        let chrome = pane.bind(t, state: stateT)
        let window = Self.window(chrome)
        defer {
            window.close()
            pane.drop()
            t.close()
            u.close()
        }
        let offer = BrowserCookieImportOffer(icons: [], title: "Import", importTitle: "Import", notNowTitle: "Not now")
        chrome.showCookieImportOffer(offer) { _ in }
        pane.bind(u, state: stateU)
        #expect(!chrome.showsCookieImportOffer)
        pane.bind(t, state: stateT)
        #expect(chrome.showsCookieImportOffer, "the offer left with the switch and never came back")
    }

    /// The cookie import card waits clear until its page measured itself: the overlay host shows what
    /// it presents at full opacity, and a present (the first, or again after a tab switch) kept that.
    @Test func aCookieOfferStaysClearUntilItsPageMeasuredItself() async {
        let t = Self.tab("t.example"), u = Self.tab("u.example")
        let stateT = BrowserChromeTabState(), stateU = BrowserChromeTabState()
        stateT.hasKeyboard = true  // the person is in tab T: its cookie offer may show
        let pane = BrowserPaneChrome()
        let chrome = pane.bind(t, state: stateT)
        let window = Self.window(chrome)
        defer {
            window.close()
            pane.drop()
            t.close()
            u.close()
        }
        let offer = BrowserCookieImportOffer(icons: [], title: "Import", importTitle: "Import", notNowTitle: "Not now")
        chrome.showCookieImportOffer(offer) { _ in }
        let card = chrome.currentCookieImportCard
        #expect(card?.superview != nil, "the card was not presented")
        #expect(card?.alphaValue == 0, "the empty card showed before its page measured it")
        pane.bind(u, state: stateU)
        pane.bind(t, state: stateT)
        #expect(card?.superview != nil, "the card did not come back with its tab")
        #expect(card?.alphaValue == 0, "presenting the card again showed it before its page measured it")
    }

    /// Leo, 2026-11-08: "the import cookies from google chrome card flickers sometimes". The card shows
    /// once and stays put: its page measuring itself, the person's keyboard leaving the tab and coming
    /// back, and the same offer shown again (Show Import Cookies Banner, a second finished load) keep the
    /// one card where it is. Each of those dismissed and presented it again (its page moved to a new view
    /// and drew a blank frame) or faded it out and a new card in.
    @Test func aCookieOfferAppearsOnceAndStaysPut() async throws {
        let t = Self.tab("t.example")
        let stateT = BrowserChromeTabState()
        stateT.hasKeyboard = true  // the person is in tab T: its cookie offer may show
        let pane = BrowserPaneChrome()
        let chrome = pane.bind(t, state: stateT)
        let window = Self.window(chrome)
        defer {
            window.close()
            pane.drop()
            t.close()
        }
        let offer = BrowserCookieImportOffer(icons: [], title: "Import", importTitle: "Import", notNowTitle: "Not now")
        var answers: [String] = []
        chrome.showCookieImportOffer(offer) { _ in answers.append("first") }
        let card = try #require(chrome.currentCookieImportCard)
        let holder = try #require(card.superview, "the card was not presented")

        card.received("size", ["height": 48, "revision": 1])
        #expect(card.isMeasured)
        #expect(card.superview === holder, "measuring itself presented the card again")

        stateT.hasKeyboard = false
        #expect(!chrome.showsCookieImportOffer, "the card shows over a terminal or chat beside the tab")
        #expect(card.superview === holder, "the keyboard leaving the tab presented the card again")
        #expect(holder.isHidden, "the waiting card stays on screen")
        stateT.hasKeyboard = true
        #expect(chrome.showsCookieImportOffer)
        #expect(card.superview === holder, "the keyboard coming back presented the card again")
        #expect(holder.isHidden == false && card.isHidden == false)

        chrome.showCookieImportOffer(offer) { _ in answers.append("second") }
        #expect(chrome.currentCookieImportCard === card, "the same offer again made a new card")
        #expect(!card.isDismissing && card.superview === holder)
        card.onChoice?(.notNow)
        #expect(answers == ["second"], "the answer goes to the latest caller once")
    }

    /// Review of #38375 (F1): the same offer shown again while another tab of the pane shows (Show
    /// Import Cookies Banner on tab U) must not take over the card held, hidden, for tab T: U gets its
    /// own card with U's answer, and T's held card never answers for U.
    @Test func theSameOfferOnAnotherTabNeverReusesTheHeldCard() async throws {
        let t = Self.tab("t.example"), u = Self.tab("u.example")
        let stateT = BrowserChromeTabState(), stateU = BrowserChromeTabState()
        stateT.hasKeyboard = true
        stateU.hasKeyboard = true
        let pane = BrowserPaneChrome()
        let chrome = pane.bind(t, state: stateT)
        let window = Self.window(chrome)
        defer {
            window.close()
            pane.drop()
            t.close()
            u.close()
        }
        let offer = BrowserCookieImportOffer(icons: [], title: "Import", importTitle: "Import", notNowTitle: "Not now")
        var answers: [String] = []
        chrome.showCookieImportOffer(offer) { _ in answers.append("t") }
        let held = try #require(chrome.currentCookieImportCard)
        pane.bind(u, state: stateU)
        #expect(held.isHidden && held.heldFor === stateT)
        chrome.showCookieImportOffer(offer) { _ in answers.append("u") }
        let shown = try #require(chrome.currentCookieImportCard)
        #expect(shown !== held, "tab U's offer reused the card held for tab T")
        #expect(chrome.showsCookieImportOffer, "tab U's offer did not show")
        shown.onChoice?(.importCookies)
        #expect(answers == ["u"])
    }

    /// Review of #38375 at df0bd78b (follow-up F1): the same offer shown again while a window toast now
    /// shows keeps its card and raises it over the toast, where it is; offered again with no toast, it
    /// comes back down.
    @Test func aReusedCookieOfferTakesTheNewToastLift() async throws {
        let t = Self.tab("t.example")
        let stateT = BrowserChromeTabState()
        stateT.hasKeyboard = true
        let pane = BrowserPaneChrome()
        let chrome = pane.bind(t, state: stateT)
        let window = Self.window(chrome)
        defer {
            window.close()
            pane.drop()
            t.close()
        }
        let offer = BrowserCookieImportOffer(icons: [], title: "Import", importTitle: "Import", notNowTitle: "Not now")
        chrome.showCookieImportOffer(offer) { _ in }
        let card = try #require(chrome.currentCookieImportCard)
        let holder = try #require(card.superview)
        holder.layoutSubtreeIfNeeded()
        // Window coordinates grow upward, whatever the overlay holder's flip: higher is a larger y.
        let bottom = { card.convert(card.bounds, to: nil).minY }
        let resting = bottom()
        #expect(chrome.pageOverlays.lift(of: card) == 0)

        chrome.showCookieImportOffer(offer, aboveToast: true) { _ in }
        #expect(chrome.currentCookieImportCard === card && card.superview === holder, "a new card or a new present")
        #expect(chrome.pageOverlays.lift(of: card) == BrowserChromeView.toastClearance)
        holder.layoutSubtreeIfNeeded()
        #expect(abs(bottom() - resting - BrowserChromeView.toastClearance) < 0.5,
                "the card did not rise by the toast clearance: \(resting) -> \(bottom())")

        chrome.showCookieImportOffer(offer) { _ in }
        holder.layoutSubtreeIfNeeded()
        #expect(chrome.pageOverlays.lift(of: card) == 0 && abs(bottom() - resting) < 0.5)
    }

    /// History is the tab's, not the toolbar's (Chrome's HistoryTabHelper): a tab that never shows, or loads while
    /// another tab of the pane shows, records its visits and finished loads then, and a later show records none again.
    @Test func aHiddenTabRecordsItsVisitsAndFinishedLoads() async {
        let history = InMemoryBrowserHistory()
        let shown = Self.tab("shown.example"), hidden = Self.tab("hidden.example")
        let a = BrowserEntry(tab: shown, history: history), b = BrowserEntry(tab: hidden, history: history)
        var finished: [URL] = []
        b.state.onPageFinished = { finished.append($0) }
        let pane = BrowserPaneChrome()
        let window = Self.window(pane.bind(b.tab, state: b.state))
        defer {
            window.close()
            pane.drop()
            a.close()
            b.close()
        }
        pane.bind(a.tab, state: a.state)
        let next = URL(string: "https://hidden.example/next")!
        hidden.load(next)
        await Self.settle()
        let visits = { history.entries.filter { $0.url == next }.map(\.visitCount).reduce(0, +) }
        #expect(visits() == 1, "the hidden tab's load is in history: \(history.entries.map(\.url))")
        #expect(finished.last == next, "the hidden tab's finished load was reported: \(finished)")
        pane.bind(b.tab, state: b.state)
        await Self.settle()
        #expect(visits() == 1, "showing the tab again records no second visit")
        let never = Self.tab("never.example")
        let c = BrowserEntry(tab: never, history: history)
        defer { c.close() }
        never.load(URL(string: "https://never.example/page")!)
        await Self.settle()
        #expect(history.entries.contains { $0.url.absoluteString == "https://never.example/page" }, "a tab never shown records its visits")
    }

    /// A tab moved to another pane while it did not show takes its held cookie import offer with it.
    @Test func aHiddenTabMovedToAnotherPaneTakesItsCookieOffer() async {
        let t = Self.tab("t.example"), u = Self.tab("u.example")
        let stateT = BrowserChromeTabState(), stateU = BrowserChromeTabState()
        stateT.hasKeyboard = true  // the person is in tab T: its cookie offer may show
        let paneA = BrowserPaneChrome(), paneB = BrowserPaneChrome()
        let chromeA = paneA.bind(t, state: stateT)
        let window = Self.window(chromeA)
        defer {
            window.close()
            paneA.drop()
            paneB.drop()
            t.close()
            u.close()
        }
        let offer = BrowserCookieImportOffer(icons: [], title: "Import", importTitle: "Import", notNowTitle: "Not now")
        chromeA.showCookieImportOffer(offer) { _ in }
        paneA.bind(u, state: stateU)
        let chromeB = paneB.bind(t, state: stateT)
        #expect(chromeB.showsCookieImportOffer, "the moved tab's offer shows in its new pane")
        #expect(chromeA.currentCookieImportCard == nil, "and no longer waits in the old one")
    }

    /// A tab switch made inside an omnibar step (a "switch to tab" row): the switched-to tab's state goes back first,
    /// and inputs queued after the switch apply to it, not to the leaving tab's state.
    @Test func inputsAfterARestoreInsideAStepApplyToTheRestoredTab() {
        let t = Self.tab("t.example")
        let chrome = BrowserChromeView(tab: t)
        defer { t.close() }
        let controller = chrome.addressBar.controller
        let resting = controller.state
        let later = URL(string: "https://later.example/")!
        let prior = controller.onStep
        var switched = false
        controller.onStep = {
            prior?()
            guard !switched else { return }
            switched = true
            controller.restore(resting)
            controller.send(.pageURLChanged(later))
        }
        controller.send(.pageURLChanged(URL(string: "https://leaving.example/")!))
        #expect(controller.state.pageURL == later, "the input after the switch was overwritten: \(String(describing: controller.state.pageURL))")
    }
}
