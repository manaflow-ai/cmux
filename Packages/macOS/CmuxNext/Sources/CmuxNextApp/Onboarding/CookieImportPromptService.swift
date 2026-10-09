import AppKit
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDesign
import Foundation

/// The cookie import card (cx-367y): once per launch, on the first web
/// page that finishes loading in the person's own Chromium tab, a small
/// glass card at the bottom of the page offers to import cookies from the
/// browsers installed on this Mac. Import Cookies opens the existing import
/// step with only cookies checked (the person picks the browser profiles
/// there); Not Now hides it for a week; Don't Show Again and a finished
/// cookie import end it for good. It reads no browser data itself: the
/// installed browsers come from Launch Services, so it never raises a
/// privacy prompt. Automation launches (`CMUX_NEXT_NO_ACTIVATE`) never see
/// it unless `CMUX_NEXT_COOKIE_PROMPT=1`.
@MainActor
final class CookieImportPromptService {
    private weak var services: AppServices?
    private let defaults: UserDefaults
    private(set) var state: CookieImportPromptState
    /// Browsers cmux can import cookies from, most used first; nil until found.
    private(set) var browsers: [InstalledCookieBrowser]?
    private var finding: Task<Void, Never>?
    private var waiting: [@MainActor ([InstalledCookieBrowser]) -> Void] = []
    private(set) var shownThisLaunch = false
    var now: () -> Date = Date.init

    static let forceKey = "CMUX_NEXT_COOKIE_PROMPT"

    /// Finds the installed browsers' apps (any thread); tests pass their own.
    private let locate: @Sendable () -> [(browser: ImportBrowser, app: URL)]
    /// Pins whether the card may show (tests); nil follows the launch.
    var enabledOverride: Bool?

    init(services: AppServices?, defaults: UserDefaults = .standard,
         locate: @escaping @Sendable () -> [(browser: ImportBrowser, app: URL)] = { InstalledCookieBrowser.locate() }) {
        self.services = services
        self.defaults = defaults
        self.locate = locate
        state = CookieImportPromptState.load(from: defaults)
    }

    private var enabled: Bool {
        enabledOverride ?? (ProcessInfo.processInfo.environment[Self.forceKey] == "1" || services?.environment.noActivate == false)
    }

    /// Wires a new browser page's chrome (`TabContentCache.onBrowserEntryCreated`).
    func attach(_ entry: BrowserEntry) {
        entry.chrome.onPageFinished = { [weak self, weak entry] url in
            guard let self, let entry else { return }
            pageFinished(url, in: entry)
        }
    }

    private func pageFinished(_ url: URL, in entry: BrowserEntry) {
        guard enabled, !shownThisLaunch, state.offers(page(url, entry), now: now()) else { return }
        findBrowsers { [weak self, weak entry] found in
            // Asked again: the person may have answered elsewhere, or moved on, while the browsers were found.
            guard let self, let entry, !found.isEmpty, !shownThisLaunch, state.offers(page(url, entry), now: now()) else { return }
            show(on: entry.chrome, browsers: found)
        }
    }

    private func page(_ url: URL, _ entry: BrowserEntry) -> CookieImportPage {
        let tab = entry.tab
        let personal = !OffTheRecordProfiles.shared.isOffTheRecord(tab.profileID) && !tab.isAgentDriven
            && BrowserProfileRecord.wireID(for: tab.profileID) != AgentBrowserProfile.id
        return CookieImportPage(url: url, isChromium: tab.engineKind == .cef, isPersonal: personal,
                                showsOtherNotice: entry.chrome.noticeText != nil)
    }

    /// Shows the card on `chrome` (also `debug.cookie_prompt show`, which skips the checks).
    func show(on chrome: BrowserChromeView, browsers: [InstalledCookieBrowser]) {
        shownThisLaunch = true
        let offer = BrowserCookieImportOffer(icons: browsers.map(\.icon), title: CookieImportPromptStrings.title,
                                             detail: CookieImportPromptStrings.detail, importTitle: CookieImportPromptStrings.importCookies,
                                             notNowTitle: CookieImportPromptStrings.notNow, neverTitle: CookieImportPromptStrings.never)
        let target = BrowserProfileRecord.wireID(for: chrome.tab.profileID)
        // A window toast (a recovered draft, an undo) sits at the bottom too: the card rises above it
        // instead of waiting (an inactive window keeps its toasts, so waiting could last the launch).
        let toast = chrome.window.map { !CmuxToastCenter.shared.toasts(in: $0).isEmpty } ?? false
        chrome.showCookieImportOffer(offer, aboveToast: toast) { [weak self] choice in self?.answer(choice, profile: target) }
    }

    /// `profile`: the cmux browser profile of the tab that showed the card;
    /// Import Cookies brings the cookies into it, so that tab stays signed in.
    func answer(_ choice: BrowserCookieImportChoice, profile: String? = nil) {
        update { $0.answer(choice, now: now()) }
        guard choice == .importCookies else { return }
        guard let onboarding = services?.onboarding else { return }
        onboarding.show(step: .importData, importKinds: [.cookies], importTarget: profile)
        // The person asked to import: finding their browsers now is theirs, not a launch-time read.
        onboarding.controller?.model.importer.detect()
    }

    /// A finished import (onboarding, the import action or this card's):
    /// once cookies came over, the card never shows again.
    func importFinished(_ summary: ImportSummary) {
        guard summary.counts.cookies > 0 else { return }
        update { $0.imported = true }
    }

    /// `debug.cookie_prompt reset`: back to a fresh Mac's state.
    func reset() {
        update { $0 = CookieImportPromptState() }
        shownThisLaunch = false
    }

    private func update(_ change: (inout CookieImportPromptState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        next.save(to: defaults)
    }

    /// Finds the installed browsers once, off the main thread, then calls
    /// `done` (at once when they are already known).
    func findBrowsers(then done: (@MainActor ([InstalledCookieBrowser]) -> Void)? = nil) {
        if let browsers { done?(browsers); return }
        if let done { waiting.append(done) }
        guard finding == nil else { return }
        // task-owner: one Launch Services lookup per launch; ends after it
        finding = Task { [weak self] in
            guard let locate = self?.locate else { return }
            let apps = await Task.detached { locate() }.value
            let found = apps.map { InstalledCookieBrowser(browser: $0.browser, icon: NSWorkspace.shared.icon(forFile: $0.app.path)) }
            guard let self else { return }
            browsers = found
            finding = nil
            let callbacks = waiting
            waiting = []
            for callback in callbacks { callback(found) }
        }
    }
}

/// A browser on this Mac that cmux can import cookies from, with its app
/// icon (Launch Services only: no file of the browser is read).
struct InstalledCookieBrowser {
    let browser: ImportBrowser
    let icon: NSImage

    /// The browsers people most often come from lead; the rest keep registry order.
    nonisolated static let leading: [ImportBrowser] = [.chrome, .edge, .firefox, .arc, .brave, .safari]

    /// Launch Services' app for a bundle id; nonisolated so the off-main search never needs the main actor.
    nonisolated static func appURL(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// The installed browsers and their apps, in offer order (any thread).
    nonisolated static func locate(_ locate: (String) -> URL? = appURL) -> [(browser: ImportBrowser, app: URL)] {
        let candidates = ImportBrowser.allCases.filter { browser in
            browser.kind == .browser && !browser.refusesSessionData && [.chromium, .firefox, .safari].contains(browser.family)
        }
        let rank = { (browser: ImportBrowser) in leading.firstIndex(of: browser) ?? leading.count }
        return candidates.sorted { rank($0) < rank($1) }.compactMap { browser in
            browser.bundleIDs.compactMap(locate).first.map { (browser: browser, app: $0) }
        }
    }
}
