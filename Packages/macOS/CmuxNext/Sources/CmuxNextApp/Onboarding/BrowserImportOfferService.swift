import AppKit
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDesign
import CmuxNextImportCards
import Foundation

/// The browser-data import offer (Lawrence 2026-10-09: no onboarding window
/// and no import flow; the browser offers its own import). The first time
/// in a launch that a person's browser tab finishes a page, a small glass
/// card at the bottom of it offers to import bookmarks, history and
/// passwords from the most used browser on this Mac. Import opens the
/// Import from Browser window with those kinds checked, into the tab's
/// profile; Not Now ends the offer for good, and so does any import that
/// brought data over (`BrowserImportOfferState`). It reads no browser data
/// itself: the installed browsers come from Launch Services, so it never
/// raises a privacy prompt. Automation launches (`CMUX_NEXT_NO_ACTIVATE`)
/// never see it unless `CMUX_NEXT_BROWSER_IMPORT_OFFER=1`.
@MainActor
final class BrowserImportOfferService {
    private weak var services: AppServices?
    private let defaults: UserDefaults
    private(set) var state: BrowserImportOfferState
    /// Browsers cmux can import from, most used first; nil until found.
    private(set) var browsers: [InstalledImportBrowser]?
    private var finding: Task<Void, Never>?
    private var waiting: [@MainActor ([InstalledImportBrowser]) -> Void] = []
    /// One card per launch: a second tab never shows it.
    private(set) var shownThisLaunch = false
    /// The chrome showing the card this launch, to hide it when browser import is turned off.
    private weak var shownOn: BrowserChromeView?

    static let forceKey = "CMUX_NEXT_BROWSER_IMPORT_OFFER"
    /// The kinds Import checks in the Import from Browser window.
    static let kinds: Set<ImportDataKind> = [.bookmarks, .history, .passwords]

    /// Finds the installed browsers' apps (any thread); tests pass their own.
    private let locate: @Sendable () -> [(browser: ImportBrowser, app: URL)]
    /// Pins whether the card may show (tests); nil follows the launch.
    var enabledOverride: Bool?

    init(services: AppServices?, defaults: UserDefaults = .standard,
         locate: @escaping @Sendable () -> [(browser: ImportBrowser, app: URL)] = { InstalledImportBrowsers().locate() }) {
        self.services = services
        self.defaults = defaults
        self.locate = locate
        state = BrowserImportOfferState.load(from: defaults)
    }

    private var enabled: Bool {
        // `browser.import.enabled` off: no offer, whatever the launch.
        guard services?.browserImportEnabled != false else { return false }
        return enabledOverride ?? (ProcessInfo.processInfo.environment[Self.forceKey] == "1" || services?.environment.noActivate == false)
    }

    /// Wires a new browser page's chrome (`TabContentCache.onBrowserEntryCreated`).
    func attach(_ entry: BrowserEntry) {
        entry.chrome.onPageFinished = { [weak self, weak entry] _ in
            guard let self, let entry else { return }
            pageFinished(in: entry)
        }
    }

    private func pageFinished(in entry: BrowserEntry) {
        guard enabled, !shownThisLaunch, state.offers(page(entry)) else { return }
        findBrowsers { [weak self, weak entry] found in
            // Asked again: the person may have answered elsewhere, or another tab showed it, while the browsers were found.
            guard let self, let entry, enabled, !found.isEmpty, !shownThisLaunch, state.offers(page(entry)) else { return }
            show(on: entry.chrome, browsers: found)
        }
    }

    private func page(_ entry: BrowserEntry) -> BrowserImportOfferPage {
        let tab = entry.tab
        // No services (a test): an empty incognito set's answer, not off the record.
        let personal = !(services?.browserStores.offTheRecord.isOffTheRecord(tab.profileID) ?? false) && !tab.isAgentDriven
            && BrowserProfileRecord.wireID(for: tab.profileID) != AgentBrowserProfile.id
        return BrowserImportOfferPage(isPersonal: personal, showsOtherNotice: entry.chrome.noticeText != nil)
    }

    /// Shows the card on `chrome` (also `debug.browser_import_offer show`, which skips the checks).
    func show(on chrome: BrowserChromeView, browsers: [InstalledImportBrowser]) {
        guard let first = browsers.first else { return }
        shownThisLaunch = true
        shownOn = chrome
        let offer = BrowserCookieImportOffer(icons: [first.icon], title: BrowserImportOfferStrings.title(browser: first.browser.displayName),
                                             detail: BrowserImportOfferStrings.detail, importTitle: BrowserImportOfferStrings.importData,
                                             notNowTitle: BrowserImportOfferStrings.notNow)
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
        case .notNow, .never:
            update { $0.dismissed = true }
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

    /// `browser.import.enabled` turned off: the card on screen goes (it is not recorded as answered),
    /// so once it is on again the next finished page may offer it again this launch.
    func importTurnedOff() {
        shownOn?.hideCookieImportOffer()
        shownOn = nil
        shownThisLaunch = false
    }

    /// A finished import (this offer's or File > Import from Browser): once
    /// data came over, the offer never shows again.
    func importFinished(_ summary: ImportSummary) {
        update { $0.recordImport(summary.counts) }
    }

    /// `debug.browser_import_offer reset`: back to a fresh Mac's state.
    func reset() {
        update { $0 = BrowserImportOfferState() }
        shownThisLaunch = false
    }

    private func update(_ change: (inout BrowserImportOfferState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        next.save(to: defaults)
    }

    /// Finds the installed browsers once, off the main thread, then calls
    /// `done` (at once when they are already known).
    func findBrowsers(then done: (@MainActor ([InstalledImportBrowser]) -> Void)? = nil) {
        if let browsers { done?(browsers); return }
        if let done { waiting.append(done) }
        guard finding == nil else { return }
        // task-owner: one Launch Services lookup per launch; ends after it
        finding = Task { [weak self] in
            guard let locate = self?.locate else { return }
            let apps = await Task.detached { locate() }.value
            let found = apps.map { InstalledImportBrowser(browser: $0.browser, icon: NSWorkspace.shared.icon(forFile: $0.app.path)) }
            guard let self else { return }
            browsers = found
            finding = nil
            let callbacks = waiting
            waiting = []
            for callback in callbacks { callback(found) }
        }
    }
}

/// A browser on this Mac that cmux can import from, with its app icon
/// (`InstalledImportBrowsers` finds them).
struct InstalledImportBrowser {
    let browser: ImportBrowser
    let icon: NSImage
}
