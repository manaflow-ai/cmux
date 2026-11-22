import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextBrowserImport
import Foundation
import Testing

/// The browser-data import offer (Lawrence 2026-10-09: no onboarding window,
/// no import flow; "when they make a browser they will see option to import
/// browser data"). The first browser tab of a launch shows one quiet card;
/// Not Now and a finished import are remembered per channel; a second tab
/// never shows it.
@MainActor
struct BrowserImportOfferTests {
    static func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "cmux-browser-import-offer-\(UUID().uuidString)"))
    }

    static func service(_ defaults: UserDefaults) -> BrowserImportOfferService {
        let service = BrowserImportOfferService(services: nil, defaults: defaults, locate: {
            [(browser: .chrome, app: URL(fileURLWithPath: "/Applications/Google Chrome.app")),
             (browser: .safari, app: URL(fileURLWithPath: "/Applications/Safari.app"))]
        })
        service.enabledOverride = true
        return service
    }

    /// A person's new browser tab, attached as `TabContentCache` does, on its first page.
    static func openTab(_ service: BrowserImportOfferService, engine: BrowserEngineKind = .cef, url: String = "about:blank",
                        agent: Bool = false) -> BrowserEntry {
        let tab = MockBrowserEngine(kind: engine).makeMockTab(BrowserTabConfiguration())
        if agent { tab.markAgentDriven() }
        let entry = BrowserEntry(tab: tab)
        service.attach(entry)
        tab.load(URL(string: url)!)
        return entry
    }

    static func settle(_ service: BrowserImportOfferService, until done: () -> Bool) async {
        for _ in 0..<500 where !done() { await Task.yield() }
    }

    @Test func theFirstBrowserTabShowsOneOffer() async throws {
        let service = Self.service(try Self.defaults())
        let entry = Self.openTab(service)
        await Self.settle(service) { entry.chrome.showsCookieImportOffer }
        #expect(entry.chrome.showsCookieImportOffer, "the first browser tab, even on its blank new page")
        let card = try #require(entry.chrome.currentCookieImportCard)
        #expect(card.shownText == [BrowserImportOfferStrings.title(browser: "Google Chrome"), BrowserImportOfferStrings.detail,
                                   BrowserImportOfferStrings.notNow, BrowserImportOfferStrings.importData],
                "one line naming the detected browser, Not Now and Import, no third answer")
        #expect(card.neverButton.isHidden)
    }

    @Test func aSecondTabNeverShowsIt() async throws {
        let service = Self.service(try Self.defaults())
        let first = Self.openTab(service)
        await Self.settle(service) { first.chrome.showsCookieImportOffer }
        let second = Self.openTab(service, url: "https://example.com/")
        await Self.settle(service) { second.chrome.showsCookieImportOffer }
        #expect(!second.chrome.showsCookieImportOffer)
    }

    @Test func notNowIsRememberedAcrossLaunches() async throws {
        let defaults = try Self.defaults()
        let service = Self.service(defaults)
        let first = Self.openTab(service)
        await Self.settle(service) { first.chrome.showsCookieImportOffer }
        service.answer(.notNow)
        #expect(service.state.dismissed)
        let relaunched = Self.service(defaults)
        let next = Self.openTab(relaunched)
        await Self.settle(relaunched) { relaunched.browsers != nil }
        await Self.settle(relaunched) { next.chrome.showsCookieImportOffer }
        #expect(!next.chrome.showsCookieImportOffer, "Not Now is remembered")
    }

    @Test func aFinishedImportIsRememberedAndAnEmptyOneIsNot() throws {
        var state = BrowserImportOfferState()
        let page = BrowserImportOfferPage(isPersonal: true, showsOtherNotice: false)
        state.recordImport(ImportCounts())
        #expect(state.offers(page), "an import that brought nothing does not end the offer")
        state.recordImport(ImportCounts(bookmarks: 3))
        #expect(!state.offers(page))
        let defaults = try Self.defaults()
        state.save(to: defaults)
        #expect(BrowserImportOfferState.load(from: defaults) == state)
    }

    @Test func itIsNeverOfferedInAnAgentsTabOrOverAnotherNotice() async throws {
        let state = BrowserImportOfferState()
        #expect(state.offers(BrowserImportOfferPage(isPersonal: true, showsOtherNotice: false)))
        #expect(!state.offers(BrowserImportOfferPage(isPersonal: false, showsOtherNotice: false)), "never incognito or an agent's tab")
        #expect(!state.offers(BrowserImportOfferPage(isPersonal: true, showsOtherNotice: true)))
        let service = Self.service(try Self.defaults())
        let agent = Self.openTab(service, agent: true)
        await Self.settle(service) { service.browsers != nil }
        #expect(!agent.chrome.showsCookieImportOffer)
        let webkit = Self.openTab(service, engine: .webkit)
        await Self.settle(service) { webkit.chrome.showsCookieImportOffer }
        #expect(webkit.chrome.showsCookieImportOffer, "bookmarks, history and passwords import into any engine's profile")
    }

    @Test func itOffersInstalledBrowsersMostUsedFirstAndNeverTor() {
        let installed: Set<String> = ["org.mozilla.firefox", "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac",
                                      "org.torproject.torbrowser"]
        let found = InstalledImportBrowser.locate { installed.contains($0) ? URL(fileURLWithPath: "/Applications/\($0).app") : nil }
        #expect(Array(found.map { $0.browser }.prefix(4)) == [.chrome, .edge, .firefox, .safari])
        #expect(!found.contains { $0.browser.refusesSessionData }, "Tor's data stays in Tor")
        #expect(InstalledImportBrowser.locate { _ in nil }.isEmpty, "no browser, no card")
    }
}
