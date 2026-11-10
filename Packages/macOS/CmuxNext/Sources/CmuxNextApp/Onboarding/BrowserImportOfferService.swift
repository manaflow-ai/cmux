import AppKit
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDesign
import CmuxNextImportCards
import CmuxNextSettings
import Foundation

/// The Import Cookies banner (Lawrence 2026-10-31). The first time in a launch
/// that a person's browser tab finishes a page that asks to sign in (a password
/// or user name field; Lawrence 2026-11-09), a glass card at its bottom
/// offers to import cookies from the most used browser on this Mac. Import
/// opens Import from Browser with cookies checked, into the tab's profile;
/// nothing is read before that click. Not Now closes it for this launch; Don't
/// Show Again turns `browser.import.cookieBanner` off (``CookieBannerSwitch``);
/// imported cookies end it (`BrowserImportOfferState`). It reads no browser
/// data itself: the installed browsers come from Launch Services. Automation launches (`CMUX_NEXT_NO_ACTIVATE`)
/// never see it unless `CMUX_NEXT_BROWSER_IMPORT_OFFER=1`.
@MainActor
final class BrowserImportOfferService {
    private weak var services: AppServices?
    private let defaults: UserDefaults
    private(set) var state: BrowserImportOfferState
    /// Finds the installed browsers once, off the main thread (``InstalledImportBrowserFinder``).
    let finder: InstalledImportBrowserFinder
    /// Browsers cmux can import from, most used first; nil until found.
    var browsers: [InstalledImportBrowser]? { finder.browsers }
    /// One card per launch: a second tab never shows it.
    private(set) var shownThisLaunch = false
    /// The chrome showing the card this launch; a tab moved to another pane takes the card to that pane's chrome.
    private weak var shownOn: BrowserChromeView?
    private func hide() { ([shownOn] + (services?.cache.browsers.values.map(\.chrome) ?? [])).forEach { $0?.hideCookieImportOffer() } }

    static let forceKey = "CMUX_NEXT_BROWSER_IMPORT_OFFER"
    /// The kinds Import checks in the Import from Browser window.
    static let kinds: Set<ImportDataKind> = [.cookies]

    /// Pins whether the card may show (tests); nil follows the launch.
    var enabledOverride: Bool?

    init(services: AppServices?, defaults: UserDefaults = .standard,
         locate: @escaping @Sendable () -> [(browser: ImportBrowser, app: URL)] = { InstalledImportBrowsers().locate() }) {
        self.services = services
        self.defaults = defaults
        finder = InstalledImportBrowserFinder(locate: locate)
        state = BrowserImportOfferState.load(from: defaults)
    }

    /// Whether the settings and the import record let the banner show (the launch aside):
    /// browser import on, `browser.import.cookieBanner` on, and no cookies imported yet.
    var isOffered: Bool { services?.browserImportEnabled != false && banner?.isOn != false && !state.imported }

    private var enabled: Bool {
        // `browser.import.enabled` or `browser.import.cookieBanner` off: no offer, whatever the launch.
        guard isOffered else { return false }
        return enabledOverride ?? (ProcessInfo.processInfo.environment[Self.forceKey] == "1" || services?.environment.noActivate == false)
    }

    /// Wires a new browser page's chrome (`TabContentCache.onBrowserEntryCreated`).
    func attach(_ entry: BrowserEntry) {
        entry.state.onPageFinished = { [weak self, weak entry] _ in
            guard let self, let entry else { return }
            pageFinished(in: entry)
        }
    }

    private func pageFinished(in entry: BrowserEntry) {
        guard enabled, !shownThisLaunch, entry.state.hasKeyboard, state.offers(page(entry)) else { return }  // never over a terminal or chat
        // task-owner: one bounded read of the finished page's DOM (no gesture, isolated world); then the offer or nothing
        Task { @MainActor [weak self, weak entry] in
            guard let entry else { return }
            let answer = try? await entry.tab.evaluate(Self.signInProbe, world: .isolated, gesture: .cmux)
            guard let self, answer == .bool(true) else { return }  // no sign-in form (or no answer): no banner
            self.offerAfterSignInCheck(in: entry)
        }
    }

    /// Whether the page shows a sign-in form: a password field, or a field the page marks for a user name
    /// or a passkey (Lawrence 2026-11-09: the banner shows only where a sign-in would come over).
    static let signInProbe = """
        !!document.querySelector('input[type=password], input[autocomplete~="current-password"], \
        input[autocomplete~="username"], input[autocomplete~="webauthn"]')
        """

    private func offerAfterSignInCheck(in entry: BrowserEntry) {
        guard enabled, !shownThisLaunch, entry.state.hasKeyboard, state.offers(page(entry)) else { return }
        finder.find { [weak self, weak entry] found in
            // Asked again: the person may have answered elsewhere, or another tab showed it, while the browsers were found.
            guard let self, let entry, enabled, !found.isEmpty, !shownThisLaunch, entry.state.hasKeyboard, state.offers(page(entry)) else { return }
            if let chrome = entry.chrome { show(on: chrome, browsers: found) }
        }
    }

    private func page(_ entry: BrowserEntry) -> BrowserImportOfferPage {
        let tab = entry.tab
        // No services (a test): an empty incognito set's answer, not off the record.
        let personal = !(services?.browserStores.offTheRecord.isOffTheRecord(tab.profileID) ?? false) && !tab.isAgentDriven
            && BrowserProfileRecord.wireID(for: tab.profileID) != AgentBrowserProfile.id
        return BrowserImportOfferPage(isPersonal: personal, showsOtherNotice: entry.state.noticeText != nil)
    }

    /// Shows the card on `chrome` (also `debug.browser_import_offer show`, which skips the checks).
    func show(on chrome: BrowserChromeView, browsers: [InstalledImportBrowser]) {
        guard let first = browsers.first else { return }
        shownThisLaunch = true
        shownOn = chrome
        let offer = BrowserCookieImportOffer(icons: [first.icon], title: BrowserImportOfferStrings.title(browser: first.browser.displayName),
                                             importTitle: BrowserImportOfferStrings.importData, notNowTitle: BrowserImportOfferStrings.notNow,
                                             neverTitle: BrowserImportOfferStrings.dontShowAgain)
        let target = BrowserProfileRecord.wireID(for: chrome.tab.profileID)
        // A window toast (a recovered draft, an undo) sits at the bottom too: the card rises above it
        // instead of waiting (an inactive window keeps its toasts, so waiting could last the launch).
        let toast = chrome.window.map { !CmuxToastCenter.shared.toasts(in: $0).isEmpty } ?? false
        chrome.showCookieImportOffer(offer, aboveToast: toast) { [weak self] choice in self?.answer(choice, profile: target) }
    }

    /// `profile`: the cmux browser profile of the tab that showed the card;
    /// Import brings the data into it.
    func answer(_ choice: BrowserCookieImportChoice, profile: String? = nil) {
        switch choice {
        case .notNow: break  // closed for this launch only: the next launch offers it again
        case .never: bannerWrite = banner?.set(false) ?? bannerWrite
        case .importCookies:
            // A card left from before browser import was turned off opens and detects nothing.
            guard services?.browserImportEnabled != false else { return }
            // Not recorded: a cancelled import offers again next launch. A finished one ends it (`importFinished`).
            guard let onboarding = services?.onboarding else { return }
            onboarding.show(step: .importData, importKinds: Self.kinds, importTarget: profile)
            // The person asked to import: finding their browsers now is theirs, not a launch-time read.
            onboarding.controller?.model.importer.detect()
        }
    }

    /// `browser.import.cookieBanner` (``CookieBannerSwitch``); nil before settings load (a test).
    private var banner: CookieBannerSwitch? { services?.settings.map(CookieBannerSwitch.init) }
    /// The last banner write this service started; its end is the write's end (tests await it).
    private(set) var bannerWrite: Task<Void, Never>?

    /// Show Import Cookies Banner (palette, CLI, MCP): turns it on again and shows it on the person's
    /// browser tab on screen. It reads no browser data: Import on the card is still the person's click.
    /// After cookies came over it changes nothing: the banner never asks again (Leo 2026-11-07).
    func showNow() {
        guard !state.imported else { return }
        bannerWrite = banner?.set(true) ?? bannerWrite
        shownThisLaunch = false
        guard let entry = services?.cache.browsers.values.sorted(by: { $0.state.hasKeyboard && !$1.state.hasKeyboard }).first(where: { $0.chrome.map { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor } == true }),
              services?.browserImportEnabled == true, page(entry).isPersonal else { return }
        finder.find { [weak self, weak entry] found in if let self, !state.imported, let chrome = entry?.chrome { show(on: chrome, browsers: found) } }
    }

    /// Off, the card on screen goes; on again, the next finished page may offer it this launch.
    func followBannerSetting(_ settings: SettingsController) -> Task<Void, Never> {
        CookieBannerSwitch(settings: settings).follow { [weak self] on, before in
            if !on { self?.hide() } else if before == false { self?.shownThisLaunch = false }
        }
    }

    /// `browser.import.enabled` turned off: the card on screen goes (it is not recorded as answered),
    /// so once it is on again the next finished page may offer it again this launch.
    func importTurnedOff() {
        hide()
        shownThisLaunch = false
    }

    /// A finished import (any path, Import Cookies included): once cookies came over, it never shows again (Leo 2026-11-07).
    func importFinished(_ counts: ImportCounts) {
        update { $0.recordImport(counts) }
        if state.imported { hide() }
    }

    /// `debug.browser_import_offer reset`: back to a fresh Mac's state, the setting on again.
    func reset() {
        update { $0 = BrowserImportOfferState() }
        shownThisLaunch = false
        bannerWrite = banner?.set(true) ?? bannerWrite
    }

    private func update(_ change: (inout BrowserImportOfferState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        next.save(to: defaults)
    }
}
