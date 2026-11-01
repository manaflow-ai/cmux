import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDesign
@testable import CmuxNextImportCards
@testable import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// The Import Cookies banner in browser tabs (Lawrence 2026-10-31: "import cookies banner on browsers
/// if user has never dismissed it yet"). A card at the bottom of the person's browser tab offers to
/// import cookies from their most used other browser. It shows once per launch until the person
/// imports cookies or clicks Don't Show Again; Not Now only closes it for this launch. Don't Show
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

        func tearDown() {
            services.onboarding.controller?.window?.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
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
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-cookie-banner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        return Harness(services: services, settings: settings, url: url)
    }

    static func freshDefaults() -> UserDefaults {
        let name = "cnc-cookie-banner-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
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
        #expect(text.first?.localizedCaseInsensitiveContains("cookies") == true, "the title offers cookies: \(text)")
        #expect(text.first?.contains("Google Chrome") == true, "and names the browser: \(text)")
        #expect(text.contains(BrowserImportOfferStrings.dontShowAgain), "Don't Show Again is one of the answers: \(text)")
        #expect(text.contains(BrowserImportOfferStrings.importData))
        #expect(text.contains(BrowserImportOfferStrings.notNow))
    }

    /// Clicking Import opens the import window with cookies checked, into the tab's profile; nothing
    /// is read before that click.
    @Test func importOpensTheImportWindowWithCookiesChecked() async throws {
        let h = try await make()
        defer { h.tearDown() }
        #expect(!h.services.onboarding.isShowing, "the banner opens nothing by itself")
        h.services.onboarding.browserImportOffer.answer(.importCookies, profile: nil)
        let model = try #require(h.services.onboarding.controller?.model)
        #expect(model.importer.kinds == [.cookies], "Import checks cookies only: \(model.importer.kinds)")
    }

    @Test func notNowClosesItOnlyForThisLaunch() {
        let defaults = Self.freshDefaults()
        let offer = BrowserImportOfferService(services: nil, defaults: defaults, locate: { [] })
        #expect(offer.state.offers(Self.personalPage))
        offer.answer(.notNow)
        let nextLaunch = BrowserImportOfferService(services: nil, defaults: defaults, locate: { [] })
        #expect(nextLaunch.state.offers(Self.personalPage), "Not Now is not a dismissal: the next launch offers again")
    }

    @Test func dontShowAgainTurnsTheSettingOffInCmuxJSON() async throws {
        let h = try await make()
        defer { h.tearDown() }
        h.services.onboarding.browserImportOffer.answer(.never)
        try await h.until { try h.storedBannerValue() == false }
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
    /// banner back on. It imports nothing.
    @Test func theShowActionUndoesADismissal() async throws {
        let h = try await make()
        defer { h.tearDown() }
        try await h.settings.set(.bool(false), at: Self.cookieBannerPath)
        #expect(h.services.registry.isAvailable("browser.showCookieImportBanner"))
        #expect(h.services.registry.perform("browser.showCookieImportBanner", invocation: ActionInvocation(origin: .cli)))
        try await h.until { try h.storedBannerValue() == true }
        #expect(try h.storedBannerValue() == true)
        #expect(!h.services.onboarding.isShowing, "showing the banner opens no import")
    }

    /// Only cookies coming over ends the banner: a bookmarks-only import keeps offering it.
    @Test func onlyACookieImportEndsTheBanner() {
        var state = BrowserImportOfferState()
        state.recordImport(ImportCounts(bookmarks: 12, history: 40))
        #expect(state.offers(Self.personalPage), "bookmarks and history alone keep the cookie banner")
        state.recordImport(ImportCounts(cookies: 3))
        #expect(!state.offers(Self.personalPage), "cookies came over: the banner is done")
    }

    /// The old offer (bookmarks, history and passwords) was a different card: its answer does not
    /// hide the cookie banner.
    @Test func theOldOffersDismissalDoesNotHideTheCookieBanner() throws {
        let defaults = Self.freshDefaults()
        defaults.set(try JSONEncoder().encode(["dismissed": true, "imported": false]), forKey: "browserImportOffer.state")
        let offer = BrowserImportOfferService(services: nil, defaults: defaults, locate: { [] })
        #expect(offer.state.offers(Self.personalPage))
    }
}
