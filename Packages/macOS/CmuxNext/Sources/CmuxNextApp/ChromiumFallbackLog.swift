import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation

/// Every time a tab that should have been Chromium opened in WebKit
/// instead (Chromium is the default engine, or the tab's record names it),
/// with the typed reason for `debug.cef`. Each fallback page says so with a
/// notice (`BrowserChromeView.showNotice`) when its page is made, not only the
/// first one of the run: the WebKit page has its own cookies, so the person must
/// be able to tell which engine a tab runs in (behavior audit 4, P6).
///
/// A tab whose record names Chromium keeps naming it, so its WebKit page is a
/// stand-in: ``webKitPages`` holds it until Chromium can open tabs, and then the
/// tab moves to Chromium at the address it shows (`TabContentCache.moveToChromium`).
@MainActor
final class ChromiumFallbackLog {
    enum Source: String {
        /// A new tab with no explicit engine (default Chromium).
        case newTab
        /// A tab whose record names Chromium (restored, reopened, created
        /// elsewhere) while CEF is missing or failed to start.
        case recordedTab
    }

    private(set) var lastReason: CEFUnavailableReason?
    private(set) var lastSource: Source?
    private(set) var count = 0
    /// True once a notice was handed to a tab.
    private(set) var notified = false
    /// Fallback tabs whose page was not created yet, by machine and surface
    /// (handles are per daemon); each one's page takes its notice.
    private var candidates: [Candidate: CEFUnavailableReason] = [:]
    /// Tabs whose record names Chromium and whose page runs in WebKit now, by
    /// tab id, with why: each moves to Chromium once Chromium can open tabs.
    private(set) var webKitPages: [String: CEFUnavailableReason] = [:]
    /// Stand-ins a pane selected when Chromium became ready (``chromiumBecameReady(in:)``): their page
    /// offers the move with a button instead of moving under the person, who may be typing in it.
    private var offered: Set<String> = []

    private struct Candidate: Hashable {
        let machine: String
        let surface: SurfaceID
    }

    /// Records a fallback for the tab on `machine`'s `surface` (nil when unknown yet).
    func record(_ reason: CEFUnavailableReason, source: Source, machine: String, surface: SurfaceID?) {
        lastReason = reason
        lastSource = source
        count += 1
        guard let surface else { return }
        candidates[Candidate(machine: machine, surface: surface)] = reason
    }

    /// The notice text when `machine`'s `surface` is a fallback tab whose page
    /// has not shown it yet (once per tab).
    func takeNotice(machine: String, surface: SurfaceID) -> String? {
        guard let reason = candidates.removeValue(forKey: Candidate(machine: machine, surface: surface)) else { return nil }
        notified = true
        return Self.notice(for: reason)
    }

    /// Tab `key`, whose record names Chromium, got a WebKit page for `reason`.
    /// Returns the notice its page shows: it runs in WebKit for now, and why.
    func noteWebKitPage(_ key: String, reason: CEFUnavailableReason) -> String {
        webKitPages[key] = reason
        notified = true
        return Self.webKitPageNotice(for: reason)
    }

    /// Whether tab `key`'s page is a WebKit stand-in for its Chromium record.
    func isWebKitPage(_ key: String) -> Bool { webKitPages[key] != nil }

    /// Tab `key` no longer has a WebKit stand-in (it moved to Chromium or closed).
    func forgetWebKitPage(_ key: String) {
        webKitPages[key] = nil
        offered.remove(key)
    }

    /// The notice of a Chromium record's WebKit page: it runs in WebKit for
    /// now, why, and, while the runtime downloads, that it moves to Chromium.
    static func webKitPageNotice(for reason: CEFUnavailableReason) -> String {
        switch reason {
        case .downloading: BrowserEngineStrings.webKitForNowDownloading
        case .downloadFailed: BrowserEngineStrings.webKitForNowDownloadFailed
        case .notBundled, .startFailed, .shutDown: notice(for: reason)
        }
    }

    static func notice(for reason: CEFUnavailableReason) -> String {
        switch reason {
        case .notBundled: BrowserEngineStrings.fallbackNotBundled
        case .downloading: BrowserEngineStrings.fallbackDownloading
        case .downloadFailed: BrowserEngineStrings.fallbackDownloadFailed
        case .startFailed, .shutDown: BrowserEngineStrings.fallbackStartFailed
        }
    }

    /// Why an explicit Chromium request is refused (localized). A download in
    /// progress or retrying gets its own text; the other reasons keep their
    /// failure detail.
    static func refusal(for reason: CEFUnavailableReason) -> String? {
        switch reason {
        case .downloading(let fraction): BrowserEngineStrings.downloading(fraction)
        case .downloadFailed: BrowserEngineStrings.downloadFailed
        case .notBundled, .startFailed, .shutDown: nil
        }
    }
}

/// A Chromium record's WebKit page and its move to Chromium (behavior audit 4, P6), on `cache`'s pages.
extension ChromiumFallbackLog {
    /// A WebKit page for `tab`, whose record names Chromium, with the fallback recorded: the page says it runs in
    /// WebKit for now and why, and it moves to Chromium once Chromium can open tabs (``movesToChromium(_:tab:in:)``).
    func page(_ tab: TabModel, url: URL?, reason: CEFUnavailableReason, in cache: TabContentCache) -> BrowserEntry {
        let browserTabs = cache.browserTabs
        record(reason, source: .recordedTab, machine: browserTabs.daemon(for: tab).machineID, surface: nil)
        let entry = browserTabs.historyStarts.page(tab, url: url, cache: cache) ?? cache.browser(for: tab.id, url: url)
        entry.chrome.showNotice(noteWebKitPage(tab.id, reason: reason))
        return cache.tracked(entry, tab)
    }

    /// Tab `key`'s page is a WebKit stand-in and Chromium can open tabs now. A stand-in no pane selected when
    /// Chromium became ready moves at its next request (a pane selecting it): it closes and a Chromium page is made at
    /// the address it showed, as Chrome loads a discarded tab when it is selected; the caller gets no page until the
    /// Chromium one is installed (`onBrowserReady`). One a pane selected then keeps its page (``chromiumBecameReady(in:)``
    /// offered the move). False when the page stays.
    func movesToChromium(_ key: String, tab: TabModel, in cache: TabContentCache) -> Bool {
        guard !offered.contains(key), cache.browserTabs.cefUnavailable() == nil else { return false }
        return move(key, tab: tab, in: cache)
    }

    /// The stand-in page of tab `key`: a live WebKit page (not a hibernated or remote-machine page in its place).
    private func standIn(_ key: String, in cache: TabContentCache) -> BrowserEntry? {
        guard isWebKitPage(key), let entry = cache.browsers[key], entry.tab is WebKitTab else { return nil }
        return entry
    }

    /// Closes tab `key`'s WebKit stand-in and makes its Chromium page at the address it showed.
    private func move(_ key: String, tab: TabModel, in cache: TabContentCache) -> Bool {
        guard let entry = standIn(key, in: cache), cache.pendingBrowsers.insert(key).inserted else { return false }
        let url = entry.tab.state.url ?? cache.recordURL(tab)
        forgetWebKitPage(key)
        cache.browserTabs.untrack(key)
        cache.browsers.removeValue(forKey: key)?.close()
        Task { @concurrent [weak self, weak cache] in await self?.makeChromiumPage(tab, key: key, url: url, in: cache) }
        return true
    }

    /// The Chromium page of a tab that moved from WebKit: it says Chromium has its own cookies. A WebKit page again
    /// when Chromium fails to make it.
    private func makeChromiumPage(_ tab: TabModel, key: String, url: URL?, in cache: TabContentCache?) async {
        guard let cache else { return }
        defer { cache.pendingBrowsers.remove(key) }
        let page: any BrowserTab
        do {
            page = try await cache.makeCEFTab(await cache.chromiumConfiguration(for: tab, key: key, url: url, origin: .user))
        } catch {
            guard let tab = cache.tabModel(key), cache.browsers[key] == nil, cache.goneTabs.tracks(key) else { return }
            _ = self.page(tab, url: url, reason: cache.browserTabs.cefUnavailable() ?? .startFailed(String(describing: error)), in: cache)
            cache.onBrowserReady?(key)
            return
        }
        guard cache.goneTabs.tracks(key) else { return page.close() } // closed while it started
        let entry = cache.install(page, for: key)
        cache.browserTabs.track(page, tabID: key)
        entry.chrome.showNotice(BrowserEngineStrings.movedToChromium)
        cache.onBrowserReady?(key)
    }

    /// Chromium's runtime was installed (`ChromiumRuntimeService.onInstalled`): a stand-in a pane selects now (its
    /// node's own state, whatever covers the window) keeps its page under the person, and its notice offers the move
    /// with a button and the cookie note; every other stand-in moves when a pane next asks for it.
    func chromiumBecameReady(in cache: TabContentCache) {
        for key in webKitPages.keys where cache.node(for: key).own == .visible {
            guard let entry = standIn(key, in: cache), offered.insert(key).inserted else { continue }
            let move = { [weak self, weak cache] in
                guard let self, let cache, let tab = cache.tabModel(key) else { return }
                offered.remove(key)
                _ = self.move(key, tab: tab, in: cache)
            }
            entry.chrome.showNotice(BrowserEngineStrings.chromiumReady, action: (title: BrowserEngineStrings.moveToChromium, run: move))
        }
    }
}

/// Engine-choice strings (default engine actions, the fallback notice).
enum BrowserEngineStrings {
    static var fallbackNotBundled: String {
        String(localized: "browser.engine.fallback.notBundled", defaultValue: "Chromium isn’t in this build, so this tab uses WebKit.", bundle: .module)
    }
    static var fallbackDownloading: String {
        String(localized: "browser.engine.fallback.downloading",
               defaultValue: "Chromium is downloading, so this tab uses WebKit. New tabs use Chromium when it’s ready.", bundle: .module)
    }
    static var fallbackDownloadFailed: String {
        String(localized: "browser.engine.fallback.downloadFailed",
               defaultValue: "Chromium couldn’t download yet, so this tab uses WebKit. cmux will try again.", bundle: .module)
    }
    /// The refusal while the download runs; `fraction` (0...1) shows as a percentage, 0 before bytes flow.
    static func downloading(_ fraction: Double?) -> String {
        let percent = (fraction ?? 0).formatted(.percent.precision(.fractionLength(0)))
        return String(localized: "browser.engine.downloading", defaultValue: "Chromium is downloading (\(percent)). Try again when it’s ready.", bundle: .module)
    }
    static var downloadFailed: String {
        String(localized: "browser.engine.downloadFailed", defaultValue: "Chromium couldn’t download yet. cmux will try again.", bundle: .module)
    }
    static var fallbackStartFailed: String {
        String(localized: "browser.engine.fallback.startFailed", defaultValue: "Chromium couldn’t start, so this tab uses WebKit.", bundle: .module)
    }
    /// A Chromium tab's WebKit page while the runtime downloads.
    static var webKitForNowDownloading: String {
        String(localized: "browser.engine.fallback.webKitForNow.downloading",
               defaultValue: "Chromium is downloading, so this tab runs in WebKit for now. It moves to Chromium when Chromium is ready.",
               bundle: .module)
    }
    /// A Chromium tab's WebKit page after the runtime download failed (cmux tries again).
    static var webKitForNowDownloadFailed: String {
        String(localized: "browser.engine.fallback.webKitForNow.downloadFailed",
               defaultValue: "Chromium couldn’t download yet, so this tab runs in WebKit for now. It moves to Chromium when Chromium is ready.",
               bundle: .module)
    }
    /// A shown Chromium tab's WebKit page once Chromium is ready: the move waits for the person.
    static var chromiumReady: String {
        String(localized: "browser.engine.fallback.chromiumReady",
               defaultValue: "Chromium is ready. This tab still runs in WebKit. Chromium has its own cookies, so sites may ask you to sign in again after the move.",
               bundle: .module)
    }
    /// The button that moves a shown tab from its WebKit page to Chromium.
    static var moveToChromium: String {
        String(localized: "browser.engine.fallback.moveToChromium", defaultValue: "Move to Chromium", bundle: .module)
    }
    /// The tab moved from its WebKit page to Chromium: the engines keep separate cookies.
    static var movedToChromium: String {
        String(localized: "browser.engine.fallback.movedToChromium",
               defaultValue: "This tab moved to Chromium at the same address. Chromium has its own cookies, so sites may ask you to sign in again.",
               bundle: .module)
    }
}
