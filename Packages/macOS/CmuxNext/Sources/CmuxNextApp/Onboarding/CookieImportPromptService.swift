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

    init(services: AppServices, defaults: UserDefaults = .standard) {
        self.services = services
        self.defaults = defaults
        state = CookieImportPromptState.load(from: defaults)
    }

    private var enabled: Bool {
        ProcessInfo.processInfo.environment[Self.forceKey] == "1" || services?.environment.noActivate == false
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
            && tab.profileID.rawValue.uuidString.lowercased() != AgentBrowserProfile.id.lowercased()
        // A window toast (a recovered draft, an undo) sits in the same spot: the card waits for a later page.
        let toast = entry.chrome.window.map { !CmuxToastCenter.shared.toasts(in: $0).isEmpty } ?? false
        return CookieImportPage(url: url, isChromium: tab.engineKind == .cef, isPersonal: personal,
                                showsOtherNotice: entry.chrome.noticeText != nil || toast)
    }

    /// Shows the card on `chrome` (also `debug.cookie_prompt show`, which skips the checks).
    func show(on chrome: BrowserChromeView, browsers: [InstalledCookieBrowser]) {
        shownThisLaunch = true
        let offer = BrowserCookieImportOffer(icons: browsers.map(\.icon), title: CookieImportPromptStrings.title,
                                             detail: CookieImportPromptStrings.detail, importTitle: CookieImportPromptStrings.importCookies,
                                             notNowTitle: CookieImportPromptStrings.notNow, neverTitle: CookieImportPromptStrings.never)
        chrome.showCookieImportOffer(offer) { [weak self] choice in self?.answer(choice) }
    }

    func answer(_ choice: BrowserCookieImportChoice) {
        update { $0.answer(choice, now: now()) }
        guard choice == .importCookies else { return }
        guard let onboarding = services?.onboarding else { return }
        onboarding.show(step: .importData, importKinds: [.cookies])
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
            let apps = await Task.detached { InstalledCookieBrowser.locate() }.value
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

    /// The installed browsers and their apps, in offer order (any thread).
    nonisolated static func locate(
        _ locate: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    ) -> [(browser: ImportBrowser, app: URL)] {
        let candidates = ImportBrowser.allCases.filter { browser in
            browser.kind == .browser && !browser.refusesSessionData && [.chromium, .firefox, .safari].contains(browser.family)
        }
        let rank = { (browser: ImportBrowser) in leading.firstIndex(of: browser) ?? leading.count }
        return candidates.sorted { rank($0) < rank($1) }.compactMap { browser in
            browser.bundleIDs.compactMap(locate).first.map { (browser: browser, app: $0) }
        }
    }
}
