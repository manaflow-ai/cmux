import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextBrowserCore
import CmuxNextBrowserImport
import CmuxNextDesign
import CmuxNextFocus
@testable import CmuxNextImportCards
@testable import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// The Import Cookies banner in browser tabs (Lawrence 2026-10-31: "import cookies banner on browsers
/// if user has never dismissed it yet"). A card at the bottom of the person's browser tab offers to
/// import cookies from their most used other browser. It shows at most once per launch, only on a
/// page that asks to sign in, until the person imports cookies or clicks Don't Show Again; Not Now
/// keeps it away for 30 days, across relaunches. Don't Show
/// Again writes `browser.import.cookieBanner: false` to cmux.json, so the dismissal lasts across
/// launches and Settings shows it; turning the setting on (Settings, `cmux settings`, or Show Import
/// Cookies Banner in the palette, CLI and MCP) brings it back. The card never imports by itself.
@MainActor @Suite(.serialized, .closesItsWindows) struct BrowserCookieBannerTests {
    static let cookieBannerPath = ["browser", "import", "cookieBanner"]
    static let personalPage = BrowserImportOfferPage(isPersonal: true, showsOtherNotice: false)

    struct Harness {
        let services: AppServices
        let settings: SettingsController
        let url: URL
        /// The import record the app's service keeps in the standard defaults before this test (put back after).
        let savedRecord: Data?

        func tearDown() {
            services.onboarding.controller?.window?.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            let key = BrowserImportOfferState.defaultsKey
            if let savedRecord { UserDefaults.standard.set(savedRecord, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }

        /// `browser.import.cookieBanner` as cmux.json holds it now (nil: absent).
        func storedBannerValue() throws -> Bool? {
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let browser = root?["browser"] as? [String: Any]
            let imports = browser?["import"] as? [String: Any]
            return imports?["cookieBanner"] as? Bool
        }

        /// Waits up to a deadline for `condition`: the settings write runs on another task.
        func until(_ condition: () throws -> Bool, within timeout: Duration = .seconds(10)) async rethrows {
            let deadline = ContinuousClock.now + timeout
            while try !condition(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    func make() async throws -> Harness {
        _ = NSApplication.shared
        // Each test starts with no cookies imported, whatever an earlier run left in the standard defaults.
        let savedRecord = UserDefaults.standard.data(forKey: BrowserImportOfferState.defaultsKey)
        UserDefaults.standard.removeObject(forKey: BrowserImportOfferState.defaultsKey)
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-cookie-banner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        return Harness(services: services, settings: settings, url: url, savedRecord: savedRecord)
    }

    static func freshDefaults() -> UserDefaults {
        let name = "cnc-cookie-banner-\(UUID().uuidString)"
        let defaults = UserDefaults(testSuiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A real browser tab's chrome in a window, as a pane shows it.
    struct Page {
        let window: NSWindow
        let chrome: BrowserChromeView
        let tab: WebKitTab

        init() {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            tab = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
            chrome = BrowserChromeView(tab: tab)
            chrome.frame = window.contentLayoutRect
            window.contentView = chrome
            window.orderFrontRegardless()
            chrome.layoutSubtreeIfNeeded()
        }

        func tearDown() {
            chrome.hideCookieImportOffer()
            chrome.closePopupPanels()
            window.orderOut(nil)
            window.close()
            tab.close()
        }
    }

    @Test func theBannerOffersToImportCookiesAndCanBeDismissedForGood() throws {
        let page = Page()
        defer { page.tearDown() }
        let offer = BrowserImportOfferService(services: nil, defaults: Self.freshDefaults(), locate: { [] })
        offer.show(on: page.chrome, browsers: [InstalledImportBrowser(browser: .chrome, icon: NSImage())])
        let card = try #require(page.chrome.currentCookieImportCard)
        let text = card.shownText
        #expect(text.first?.localizedCaseInsensitiveContains("sign-ins") == true, "the title offers sign-ins: \(text)")
        #expect(text.first?.contains("Google Chrome") == true, "and names the browser: \(text)")
        #expect(text.contains(BrowserImportOfferStrings.never(browser: "Chrome")), "Never for Chrome is one of the answers: \(text)")
        #expect(text.contains(BrowserImportOfferStrings.importData))
        #expect(text.contains(BrowserImportOfferStrings.notNow))
    }

    /// The card belongs to browser pages only (Lawrence 2026-11-07: it showed over a terminal and agent
    /// workspace). It floats on the window's overlay host, above every pane, so it shows only while its
    /// own browser tab has the keyboard, as the window's focus reports it (`followKeyboard`). While a
    /// terminal, a chat, Home, the sidebar or another browser tab has it, the card is hidden where it is
    /// on the overlay host and takes no clicks, unanswered; it shows again in place when its tab has the
    /// keyboard again, with no new present (Leo 2026-11-08: "the import cookies from google chrome card
    /// flickers sometimes"). A card offered while the tab lacks the keyboard (Show Import Cookies Banner
    /// from a terminal) waits off the overlay host for it.
    @Test func theCardShowsOnlyWhileItsBrowserTabHasTheKeyboard() throws {
        let page = Page()
        defer { page.tearDown() }
        let entry = BrowserEntry(tab: page.tab)
        page.chrome.bind(page.tab, state: entry.state)
        let offer = BrowserImportOfferService(services: nil, defaults: Self.freshDefaults(), locate: { [] })

        entry.followKeyboard(focusedTab: nil, key: "browser-1", window: page.window)  // a terminal has the keyboard
        offer.show(on: page.chrome, browsers: [InstalledImportBrowser(browser: .chrome, icon: NSImage())])
        let card = try #require(page.chrome.currentCookieImportCard)
        #expect(!page.chrome.showsCookieImportOffer, "offered while a terminal has the keyboard: it waits")
        #expect(card.window?.parent !== page.window, "and is not on the overlay host over the terminal")

        entry.followKeyboard(focusedTab: "browser-1", key: "browser-1", window: page.window)
        #expect(page.chrome.showsCookieImportOffer, "its browser tab has the keyboard: shown")
        #expect(card.window?.parent === page.window, "on the window's overlay host")

        entry.followKeyboard(focusedTab: nil, key: "browser-1", window: NSWindow())
        #expect(page.chrome.showsCookieImportOffer, "another window's focus does not decide this window's card")

        for away in [nil, "browser-2"] as [String?] {  // a terminal, chat, Home or the sidebar; another browser tab
            entry.followKeyboard(focusedTab: away, key: "browser-1", window: page.window)
            #expect(!page.chrome.showsCookieImportOffer, "hidden while \(away ?? "a terminal") has the keyboard")
            #expect(card.isHiddenOrHasHiddenAncestor, "and hidden where it is on the overlay host")
            #expect(page.chrome.pageOverlays.takesMouse(card) != true, "taking no clicks over the terminal")
        }

        entry.followKeyboard(focusedTab: "browser-1", key: "browser-1", window: page.window)
        #expect(page.chrome.showsCookieImportOffer, "back on its tab: shown again, still unanswered")
        #expect(page.chrome.currentCookieImportCard === card)
        #expect(card.window?.parent === page.window)
        #expect(!card.isHiddenOrHasHiddenAncestor)
    }

    /// The card's page measured itself (it fades in then): the person can see it.
    static func measure(_ card: BrowserCookieImportCard) {
        card.received("size", ["height": 60, "revision": card.pushedState["revision"] as? Int ?? 0])
    }

    /// Leo 2026-11-22: "the whole import sign in to google chrome fires too often" ... "or maybe it just
    /// "appears" to close when you unfocus and then the thing reappears when you refocus. idk. it just needs a
    /// better lifecycle". Once the person saw the card on its tab, the tab losing the keyboard closes it: refocus
    /// does not bring it back, and nor does another tab of the pane showing and this one coming back.
    @Test func aSeenCardClosesOnBlurAndNeverComesBackOnRefocus() throws {
        let page = Page()
        defer { page.tearDown() }
        let entry = BrowserEntry(tab: page.tab)
        page.chrome.bind(page.tab, state: entry.state)
        let offer = BrowserImportOfferService(services: nil, defaults: Self.freshDefaults(), locate: { [] })
        entry.followKeyboard(focusedTab: "browser-1", key: "browser-1", window: page.window)
        offer.show(on: page.chrome, browsers: [InstalledImportBrowser(browser: .chrome, icon: NSImage())])
        let card = try #require(page.chrome.currentCookieImportCard)
        Self.measure(card)
        #expect(page.chrome.showsCookieImportOffer && card.wasSeen, "shown on its focused tab: seen")

        entry.followKeyboard(focusedTab: nil, key: "browser-1", window: page.window)  // a terminal has the keyboard
        #expect(page.chrome.currentCookieImportCard == nil, "seen, then the tab lost the keyboard: it closed")
        entry.followKeyboard(focusedTab: "browser-1", key: "browser-1", window: page.window)
        #expect(!page.chrome.showsCookieImportOffer, "refocus does not bring it back")
        #expect(page.chrome.currentCookieImportCard == nil)
    }

    /// The card shows by itself at most once on a browser profile, answered or not: never on a later launch,
    /// another tab of the profile, or a refocus. Show Import Cookies Banner asks again.
    @Test func theCardOffersItselfOncePerProfileAcrossRelaunches() throws {
        let page = Page()
        defer { page.tearDown() }
        let defaults = Self.freshDefaults()
        let profile = BrowserProfileRecord.wireID(for: page.tab.profileID)
        let here = BrowserImportOfferPage(isPersonal: true, showsOtherNotice: false, profile: profile)
        let other = BrowserImportOfferPage(isPersonal: true, showsOtherNotice: false, profile: "another-profile")
        let offer = BrowserImportOfferService(services: nil, defaults: defaults, locate: { [] })
        #expect(offer.state.offers(here))
        offer.show(on: page.chrome, browsers: [InstalledImportBrowser(browser: .chrome, icon: NSImage())])
        #expect(!offer.state.offers(here), "shown on this profile: never again by itself")
        #expect(offer.state.offers(other), "another profile may still be offered it once")
        let nextLaunch = BrowserImportOfferService(services: nil, defaults: defaults, locate: { [] })
        #expect(!nextLaunch.state.offers(here), "a relaunch keeps it: the card does not come back unanswered")
    }

    /// Leo 2026-11-22: "the import from chrome apperaing on every single focus and never expiring is still not
    /// merged". Whatever happened to the card (only seen, Not now, Never for Chrome, or cookies imported), the
    /// tab losing and getting back the keyboard never brings it back, and the profile is never offered it
    /// again by itself, also after a relaunch (within Not now's 30 days for Not now).
    @Test(arguments: ["seen", "notNow", "never", "imported"])
    func theCardNeverComesBackOnFocusOnceSeenOrAnswered(_ outcome: String) throws {
        let page = Page()
        defer { page.tearDown() }
        let defaults = Self.freshDefaults()
        let entry = BrowserEntry(tab: page.tab)
        page.chrome.bind(page.tab, state: entry.state)
        let offer = BrowserImportOfferService(services: nil, defaults: defaults, locate: { [] })
        let here = BrowserImportOfferPage(isPersonal: true, showsOtherNotice: false, profile: BrowserProfileRecord.wireID(for: page.tab.profileID))
        entry.followKeyboard(focusedTab: "browser-1", key: "browser-1", window: page.window)
        #expect(offer.state.offers(here))
        offer.show(on: page.chrome, browsers: [InstalledImportBrowser(browser: .chrome, icon: NSImage())])
        let card = try #require(page.chrome.currentCookieImportCard)
        Self.measure(card)
        #expect(page.chrome.showsCookieImportOffer)
        switch outcome {
        case "notNow", "never": card.received("command", ["type": outcome])
        case "imported": offer.importFinished(ImportCounts(cookies: 5))
        default: break
        }
        if outcome != "seen" { #expect(page.chrome.currentCookieImportCard == nil, "\(outcome): the card closed") }
        for _ in 0..<3 {
            entry.followKeyboard(focusedTab: nil, key: "browser-1", window: page.window)
            entry.followKeyboard(focusedTab: "browser-1", key: "browser-1", window: page.window)
            #expect(!page.chrome.showsCookieImportOffer, "\(outcome): refocus does not bring it back")
            #expect(page.chrome.currentCookieImportCard == nil)
        }
        #expect(!offer.state.offers(here), "\(outcome): not offered again this launch")
        let nextLaunch = BrowserImportOfferService(services: nil, defaults: defaults, locate: { [] })
        #expect(!nextLaunch.state.offers(here), "\(outcome): nor after a relaunch")
        if outcome == "notNow" {
            #expect(nextLaunch.state.waitsAfterNotNow(now: Date().addingTimeInterval(29 * 24 * 3600)), "Not now holds 30 days")
        }
        if outcome == "imported" {
            var fresh = nextLaunch.state
            fresh.askAgain()
            #expect(!fresh.offers(here), "after an import, nothing asks again")
        }
    }

    /// Show Import Cookies Banner asks again, also on a profile the card already showed on.
    @Test func showImportCookiesBannerAsksAgainOnAShownProfile() {
        let defaults = Self.freshDefaults()
        let page = BrowserImportOfferPage(isPersonal: true, showsOtherNotice: false, profile: "default")
        var state = BrowserImportOfferState()
        state.recordShown(on: "default")
        state.save(to: defaults)
        let offer = BrowserImportOfferService(services: nil, defaults: defaults, locate: { [] })
        #expect(!offer.state.offers(page))
        offer.showNow()
        #expect(offer.state.offers(page), "asked for: showing before no longer holds it back")
    }

    /// Leo 2026-11-22, on a try copy's "Data Access Blocked" notice: a `cmux app try` copy is a new app to
    /// macOS, with its own defaults, so it would ask on every copy. It never offers the card by itself.
    @Test func aTryCopyNeverOffersTheCardByItself() {
        let tryCopy = "com.cmuxterm.app.nightly.side-try-feat-agent-send-pop-f03f49-f7de48"
        #expect(!BrowserImportOfferState.launchOffers(noActivate: false, bundleID: tryCopy, forced: false))
        #expect(BrowserImportOfferState.launchOffers(noActivate: false, bundleID: "com.cmuxterm.app.nightly", forced: false))
        #expect(!BrowserImportOfferState.launchOffers(noActivate: true, bundleID: "com.cmuxterm.app.nightly", forced: false))
        #expect(BrowserImportOfferState.launchOffers(noActivate: false, bundleID: tryCopy, forced: true), "forced: tests and demos")
    }

    /// A record from before profiles were kept still reads, with no profile shown on.
    @Test func aRecordWithoutShownProfilesStillReads() {
        let defaults = Self.freshDefaults()
        defaults.set(Data(#"{"imported":false}"#.utf8), forKey: BrowserImportOfferState.defaultsKey)
        let state = BrowserImportOfferState.load(from: defaults)
        #expect(state.shownOn == nil)
        #expect(state.offers(BrowserImportOfferPage(isPersonal: true, showsOtherNotice: false, profile: "default")))
    }

    /// Only a browser tab's own targets count as the browser tab having the keyboard.
    @Test(arguments: [
        (FocusState.Resolved.browserPage(pane: "p", tab: "t"), "t" as String?),
        (.addressBar(pane: "p", tab: "t"), "t"), (.findBar(pane: "p", tab: "t"), "t"), (.devTools(pane: "p", tab: "t"), "t"),
        (.terminal(pane: "p", tab: "t"), nil), (.agentPage(pane: "p", tab: "t"), nil), (.page(pane: "p", tab: "t"), nil),
        (.conversation(pane: "p", tab: "t"), nil), (.emptyPane(pane: "p"), nil), (.sidebar, nil), (.textField, nil), (.none, nil),
    ])
    func onlyABrowserTabsTargetsAreItsFocus(resolved: FocusState.Resolved, tab: String?) {
        #expect(resolved.browserTab == tab)
    }

    /// Clicking Import opens the import window with cookies checked, into the tab's profile; nothing
    /// is read before that click.
    @Test func importOpensTheImportWindowWithCookiesChecked() async throws {
        let h = try await make()
        defer { h.tearDown() }
        #expect(!(h.services.onboarding.controller != nil), "the banner opens nothing by itself")
        h.services.onboarding.browserImportOffer.answer(.importCookies, profile: nil)
        let model = try #require(h.services.onboarding.controller?.model)
        #expect(model.importer.kinds == [.cookies], "Import checks cookies only: \(model.importer.kinds)")
    }

    /// David Beyer, Nov 20 call: no nagging. Not Now keeps the card away across relaunches too (a
    /// nightly relaunches every day for its update), not only for this launch.
    @Test func notNowKeepsTheCardAwayAfterARelaunch() {
        let defaults = Self.freshDefaults()
        let offer = BrowserImportOfferService(services: nil, defaults: defaults, locate: { [] })
        #expect(offer.state.offers(Self.personalPage))
        offer.answer(.notNow)
        let nextLaunch = BrowserImportOfferService(services: nil, defaults: defaults, locate: { [] })
        #expect(!nextLaunch.state.offers(Self.personalPage), "Not Now is kept: the next launch does not ask again")
    }

    /// A Not Now lasts 30 days, then a sign-in page may offer the card once more.
    @Test func notNowLastsThirtyDays() {
        let clicked = Date(timeIntervalSince1970: 1_800_000_000)
        var state = BrowserImportOfferState()
        state.recordNotNow(at: clicked)
        #expect(!state.offers(Self.personalPage, now: clicked.addingTimeInterval(8 * 24 * 3600)), "a week and a day later: still away")
        #expect(!state.offers(Self.personalPage, now: clicked.addingTimeInterval(29 * 24 * 3600)), "29 days later: still away")
        #expect(state.offers(Self.personalPage, now: clicked.addingTimeInterval(30 * 24 * 3600 + 1)), "30 days later: offered again")
    }

    /// A record saved before Not Now was kept (only `imported`) still reads, with no Not Now in it.
    @Test func anOlderRecordStillReads() throws {
        let defaults = Self.freshDefaults()
        defaults.set(Data(#"{"imported":false}"#.utf8), forKey: BrowserImportOfferState.defaultsKey)
        let state = BrowserImportOfferState.load(from: defaults)
        #expect(state.notNowUntil == nil)
        #expect(state.offers(Self.personalPage))
    }

    /// A browser tab on a live page, wired to `offer` as the app wires a new page
    /// (`TabContentCache.onBrowserEntryCreated` calls `attach`), with the keyboard.
    struct OfferedPage {
        let page = Page()
        let entry: BrowserEntry
        let offer: BrowserImportOfferService

        init() {
            entry = BrowserEntry(tab: page.tab)
            page.chrome.bind(page.tab, state: entry.state)
            entry.followKeyboard(focusedTab: "browser-1", key: "browser-1", window: page.window)
            offer = BrowserImportOfferService(services: nil, defaults: BrowserCookieBannerTests.freshDefaults(),
                                              locate: { [(browser: .chrome, app: URL(fileURLWithPath: "/System/Applications/Safari.app"))] })
            offer.enabledOverride = true
            offer.attach(entry)
        }

        /// Shows `html` as the page at `url`, as a site would serve it.
        func show(_ html: String, at url: String) throws {
            page.tab.webView.loadHTMLString(html, baseURL: try #require(URL(string: url)))
        }

        /// Waits for the card, or the deadline: the page's own script runs on its own time.
        func waitForCard(within timeout: Duration = .seconds(10)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while page.chrome.currentCookieImportCard == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return page.chrome.currentCookieImportCard != nil
        }
    }

    /// David Beyer, Nov 20 call: "no prompt to import cookies". Most sign-in pages are apps that draw
    /// their form after the page loads (Discord, Figma, Cloudflare: no sign-in field at load, one a
    /// moment later), so a check made only when the load ends never saw a sign-in page there.
    @Test func aSignInFormDrawnAfterTheLoadOffersTheCard() async throws {
        let p = OfferedPage()
        defer { p.page.tearDown() }
        try p.show("""
            <!doctype html><body><div id=app></div><script>
            setTimeout(() => { document.getElementById('app').innerHTML =
              '<form><input type=text autocomplete="username"><input type=password></form>' }, 400)
            </script></body>
            """, at: "https://app.example.com/")
        #expect(await p.waitForCard(), "a sign-in form drawn after the load offers the card")
    }

    /// An email-first sign-in page (ChatGPT's /auth/login: one email field, no password yet, no
    /// username hint) asks the person to sign in too.
    @Test func anEmailFirstSignInPageOffersTheCard() async throws {
        let p = OfferedPage()
        defer { p.page.tearDown() }
        try p.show("<!doctype html><form><input type=email name=email autocomplete=email><button>Continue</button></form>",
                   at: "https://chat.example.com/auth/login")
        #expect(await p.waitForCard(), "an email field on a sign-in address offers the card")
    }

    /// An ordinary page never offers it, also once its scripts ran: a newsletter's email field is no sign-in.
    @Test func anOrdinaryPageWithAnEmailFieldDoesNotOfferTheCard() async throws {
        let p = OfferedPage()
        defer { p.page.tearDown() }
        try p.show("<!doctype html><h1>News</h1><form><input type=email autocomplete=email><button>Subscribe</button></form>",
                   at: "https://news.example.com/articles/today")
        #expect(!(await p.waitForCard(within: .seconds(2))), "a newsletter field is not a sign-in page")
    }

    @Test func permanentDismissalTurnsTheSettingOffInCmuxJSON() async throws {
        let h = try await make()
        defer { h.tearDown() }
        h.services.onboarding.browserImportOffer.answer(.never)
        // `setSetting` writes cmux.json and then reloads the snapshot (`reloadAfterWrite`): wait for both.
        try await h.until { try h.storedBannerValue() == false && !h.settings.snapshot.browserImportCookieBanner }
        #expect(try h.storedBannerValue() == false, "the dismissal is kept in cmux.json, across launches")
        #expect(h.settings.snapshot.browserImportCookieBanner == false)
        #expect(!h.services.onboarding.browserImportOffer.isOffered, "a dismissed banner is not offered")
    }

    /// The setting turned on again (Settings, `cmux settings set`) brings the banner back this launch.
    @Test func turningTheSettingOnBringsTheBannerBack() async throws {
        let h = try await make()
        defer { h.tearDown() }
        let offer = h.services.onboarding.browserImportOffer
        h.services.onboarding.followImportSetting(h.settings)
        try await h.settings.set(.bool(false), at: Self.cookieBannerPath)
        await h.until { !offer.isOffered }
        #expect(!offer.isOffered)
        try await h.settings.set(.bool(true), at: Self.cookieBannerPath)
        await h.until { offer.isOffered }
        #expect(offer.isOffered, "on again: the next finished page offers it")
        #expect(!offer.shownThisLaunch)
    }

    /// Show Import Cookies Banner (palette, `cmux browser show-cookie-banner`, MCP): turns a dismissed
    /// banner back on. It imports nothing. On is the row's default, so the write removes the key
    /// (#38119: an unset key follows its default) and the snapshot reads it on.
    @Test func theShowActionUndoesADismissal() async throws {
        let h = try await make()
        defer { h.tearDown() }
        try await h.settings.set(.bool(false), at: Self.cookieBannerPath)
        #expect(h.services.registry.isAvailable("browser.showCookieImportBanner"))
        #expect(h.services.registry.perform("browser.showCookieImportBanner", invocation: ActionInvocation(origin: .cli)))
        try await h.until { try h.storedBannerValue() == nil && h.settings.snapshot.browserImportCookieBanner }
        #expect(try h.storedBannerValue() == nil, "on is the default: cmux.json drops the dismissal and keeps no copy")
        #expect(h.settings.snapshot.browserImportCookieBanner, "the banner is on again")
        #expect(!(h.services.onboarding.controller != nil), "showing the banner opens no import")
    }

    /// Leo, 2026-11-07: "If someone's, like, successfully imported it" it should not ask again. After
    /// cookies came over, Show Import Cookies Banner changes nothing: the setting stays and no card shows.
    @Test func theShowActionAsksNothingAfterAnImport() async throws {
        let h = try await make()
        defer { h.tearDown() }
        try await h.settings.set(.bool(false), at: Self.cookieBannerPath)
        let offer = h.services.onboarding.browserImportOffer
        offer.importFinished(ImportCounts(cookies: 3))
        #expect(h.services.registry.perform("browser.showCookieImportBanner", invocation: ActionInvocation(origin: .cli)))
        // Every banner write the action could start is `bannerWrite`: wait for its end, not a while.
        #expect(offer.bannerWrite == nil, "the action wrote browser.import.cookieBanner after cookies came over")
        await offer.bannerWrite?.value
        #expect(try h.storedBannerValue() == false, "the action turned the banner back on after cookies came over")
        #expect(!offer.shownThisLaunch)
    }

    /// Only cookies coming over ends the banner: a bookmarks-only import keeps offering it.
    @Test func onlyACookieImportEndsTheBanner() {
        var state = BrowserImportOfferState()
        state.recordImport(ImportCounts(bookmarks: 12, history: 40))
        #expect(state.offers(Self.personalPage), "bookmarks and history alone keep the cookie banner")
        state.recordImport(ImportCounts(cookies: 3))
        #expect(!state.offers(Self.personalPage), "cookies came over: the banner is done")
    }

    /// Leo, 2026-11-07: "why does it keep asking? ... If someone's, like, successfully imported it".
    /// Cookies that came over through Import Cookies from Browser (`cmux browser import-cookies`, the
    /// palette, an agent's run the person allowed) end the banner too, across launches, and close a
    /// card on screen; a run that wrote nothing keeps it.
    @Test func cookiesImportedByTheImportCookiesCommandEndTheBannerForGood() throws {
        let page = Page()
        defer { page.tearDown() }
        let defaults = Self.freshDefaults()
        let offer = BrowserImportOfferService(services: nil, defaults: defaults, locate: { [] })
        offer.show(on: page.chrome, browsers: [InstalledImportBrowser(browser: .chrome, icon: NSImage())])
        offer.importFinished(ImportCounts(cookies: 0))
        #expect(offer.state.offers(Self.personalPage), "a run that wrote no cookie keeps the banner")
        #expect(page.chrome.currentCookieImportCard != nil)
        offer.importFinished(ImportCounts(cookies: 42))
        #expect(!offer.state.offers(Self.personalPage), "cookies came over: the banner is done")
        #expect(page.chrome.currentCookieImportCard == nil, "and the card on screen goes")
        let nextLaunch = BrowserImportOfferService(services: nil, defaults: defaults, locate: { [] })
        #expect(!nextLaunch.state.offers(Self.personalPage), "never again, also after a relaunch")
    }

    /// The old offer (bookmarks, history and passwords) was a different card: its answer does not
    /// hide the cookie banner.
    @Test func theOldOffersDismissalDoesNotHideTheCookieBanner() throws {
        let defaults = Self.freshDefaults()
        defaults.set(try JSONEncoder().encode(["dismissed": true, "imported": false]), forKey: "browserImportOffer.state")
        let offer = BrowserImportOfferService(services: nil, defaults: defaults, locate: { [] })
        #expect(offer.state.offers(Self.personalPage))
    }

    /// Lawrence 2026-11-09 (msg 26162): the banner shows less often. Only a page that asks the person to
    /// sign in (a password or username field) offers it; an ordinary page never does.
    @Test func onlyAPageThatAsksToSignInOffersTheBanner() {
        let state = BrowserImportOfferState()
        #expect(state.offers(BrowserImportOfferPage(isPersonal: true, showsOtherNotice: false, asksSignIn: true)))
        #expect(!state.offers(BrowserImportOfferPage(isPersonal: true, showsOtherNotice: false, asksSignIn: false)))
    }
}
