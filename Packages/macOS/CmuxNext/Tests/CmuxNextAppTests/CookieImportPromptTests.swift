import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextBrowserImport
import Foundation
import Testing

/// cx-367y: when the cookie import card may show, what each answer does,
/// that its state survives a relaunch, and which browsers it offers.
@MainActor
struct CookieImportPromptTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func page(_ url: String = "https://github.com/", chromium: Bool = true, personal: Bool = true, notice: Bool = false) -> CookieImportPage {
        CookieImportPage(url: URL(string: url)!, isChromium: chromium, isPersonal: personal, showsOtherNotice: notice)
    }

    @Test func aFreshMacOffersItOnlyOnPersonalChromiumWebPages() {
        let state = CookieImportPromptState()
        #expect(state.offers(Self.page(), now: Self.now))
        #expect(state.offers(Self.page("http://example.com/"), now: Self.now))
        #expect(!state.offers(Self.page("about:blank"), now: Self.now))
        #expect(!state.offers(Self.page("cmux://history"), now: Self.now))
        #expect(!state.offers(Self.page("file:///tmp/a.html"), now: Self.now))
        #expect(!state.offers(Self.page(chromium: false), now: Self.now), "cookies go into Chromium profiles")
        #expect(!state.offers(Self.page(personal: false), now: Self.now), "never incognito or an agent's tab")
        #expect(!state.offers(Self.page(notice: true), now: Self.now), "never over another notice")
    }

    @Test func notNowSnoozesForAWeekAndNeverEndsIt() {
        var state = CookieImportPromptState()
        state.answer(.notNow, now: Self.now)
        #expect(!state.offers(Self.page(), now: Self.now.addingTimeInterval(6 * 24 * 3600)))
        #expect(state.offers(Self.page(), now: Self.now.addingTimeInterval(7 * 24 * 3600)))
        state.answer(.never, now: Self.now)
        #expect(!state.offers(Self.page(), now: Self.now.addingTimeInterval(365 * 24 * 3600)))
    }

    @Test func importCookiesSnoozesSoACancelledImportDoesNotBringItBack() {
        var state = CookieImportPromptState()
        state.answer(.importCookies, now: Self.now)
        #expect(!state.offers(Self.page(), now: Self.now.addingTimeInterval(3600)))
        state.imported = true
        #expect(!state.offers(Self.page(), now: Self.now.addingTimeInterval(365 * 24 * 3600)), "never again after cookies came over")
    }

    @Test func theStateSurvivesARelaunch() throws {
        let defaults = try #require(UserDefaults(suiteName: "cmux-cookie-prompt-\(UUID().uuidString)"))
        #expect(CookieImportPromptState.load(from: defaults) == CookieImportPromptState())
        var state = CookieImportPromptState()
        state.answer(.notNow, now: Self.now)
        state.save(to: defaults)
        #expect(CookieImportPromptState.load(from: defaults) == state)
    }

    @Test func itOffersInstalledBrowsersMostUsedFirstAndNeverTor() {
        let installed: Set<String> = ["org.mozilla.firefox", "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac",
                                      "org.torproject.torbrowser"]
        let found = InstalledCookieBrowser.find(locate: { installed.contains($0) ? URL(fileURLWithPath: "/Applications/\($0).app") : nil },
                                                icon: { _ in NSImage(size: NSSize(width: 16, height: 16)) })
        #expect(Array(found.map(\.browser).prefix(4)) == [.chrome, .edge, .firefox, .safari])
        #expect(!found.contains { $0.browser.refusesSessionData }, "Tor's cookies stay in Tor")
        #expect(InstalledCookieBrowser.find(locate: { _ in nil }, icon: { _ in NSImage() }).isEmpty, "no browser, no card")
    }
}
