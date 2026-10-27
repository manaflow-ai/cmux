import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import os

/// A Chromium tab in a process whose Chromium failed to start is shown as "Chromium unavailable"; its URL never
/// loads in WebKit. `CefInitialize` runs once per process, so the notice asks for a restart of cmux; Reload asks
/// the engine again (and loads once Chromium can serve the tab). WebKit has none of Chromium's cookies, so a signed-in page came back
/// signed out (github.com/login?return_to=…) and looked like a reload (field log, 2026-10-26). A new tab never
/// gets here as Chromium once the failure is known: the engine resolver gives it WebKit when it opens.
nonisolated enum ChromiumUnavailableRestore {
    /// Whether a Chromium record that cannot get Chromium for `reason` waits in place instead of loading in
    /// WebKit. Only a start failure: a build without Chromium (`notBundled`) or one still downloading it keeps
    /// the WebKit fallback and its notice.
    static func holds(_ reason: CEFUnavailableReason) -> Bool {
        if case .startFailed = reason { return true }
        return false
    }
}

extension TabContentCache {
    private static let unavailableLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "browser.engine")

    /// The page of Chromium record `tab` when Chromium is unavailable for `reason`: the "Chromium unavailable"
    /// stand-in when Chromium failed to start, else the WebKit fallback.
    func chromiumUnavailable(_ tab: TabModel, url: URL?, reason: CEFUnavailableReason) -> BrowserEntry {
        guard ChromiumUnavailableRestore.holds(reason) else {
            return fallBack(tab, url: url, reason: reason)
        }
        let key = tab.id
        Self.unavailableLogger.notice("tab \(key, privacy: .public) waits: Chromium unavailable (\(reason.code, privacy: .public)); its page is not loaded in WebKit")
        // The tab's own profile: an incognito tab's URL must not show in another profile's suggestions.
        let page = DeferredBrowserTab(id: BrowserTabID(rawValue: key), engine: .cef, profile: browserProfile?(key) ?? .default,
                                      url: url, title: tab.title.isEmpty ? nil : tab.title)
        page.onStart = { [weak self] url in self?.retryChromium(key, url: url) }
        let entry = install(page, for: key)
        entry.chrome.showNotice(BrowserEngineStrings.chromiumUnavailableRestoredTab)
        return entry
    }

    /// Reload (or an address) on a "Chromium unavailable" tab: the tab asks for its page again, which waits again
    /// while Chromium still cannot serve it (in this process, until cmux restarts).
    private func retryChromium(_ key: String, url: URL?) {
        browsers.removeValue(forKey: key)?.close()
        guard let tab = tabModel(key) else { return }  // a remote machine's tab included
        if let entry = browser(for: tab), !(entry.tab is DeferredBrowserTab), let url, url.absoluteString != tab.url { entry.tab.load(url) }
        onBrowserReady?(key)
    }
}
