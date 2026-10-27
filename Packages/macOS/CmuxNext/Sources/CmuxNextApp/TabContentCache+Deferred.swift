import CmuxNextBrowser
import Foundation
import CmuxNextDaemon
import os

/// Restored pages that load nothing until the user starts them (after two
/// quick unexpected ends in a row, `defersRestoredPages`).
extension TabContentCache {
    /// A page that loads nothing until the user reloads it; then the real
    /// page replaces it (same key, same record).
    func deferred(_ tab: TabModel, url: URL?) -> BrowserEntry {
        let key = tab.id
        let engine: BrowserEngineKind = tab.browserEngine == BrowserEngineTag.cef.rawValue ? .cef : .webkit
        let page = DeferredBrowserTab(id: BrowserTabID(rawValue: key), engine: engine, url: url, title: tab.title.isEmpty ? nil : tab.title)
        page.onStart = { [weak self] url in self?.startDeferred(key, url: url) }
        let entry = install(page, for: key)
        entry.chrome.showNotice(CrashStrings.deferredPageNotice)
        return entry
    }

    func startDeferred(_ key: String, url: URL?) {
        startedDeferred.insert(key)
        browsers.removeValue(forKey: key)?.close()
        guard let tab = browserTabs.tabModel(key) else { return }
        if let entry = browser(for: tab), let url, url.absoluteString != tab.url { entry.tab.load(url) }
        onBrowserReady?(key)
    }
}

/// A Chromium tab in a process whose Chromium failed to start is shown as "Chromium unavailable"; its URL never
/// loads in WebKit (`CEFUnavailableReason.keepsChromiumTabsOutOfWebKit`). The notice asks for a restart of cmux;
/// Reload asks the engine again. A new tab never gets here as Chromium once the failure is known: the engine
/// resolver gives it WebKit when it opens.
extension TabContentCache {
    private static let unavailableLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "browser.engine")

    /// The page of Chromium record `tab` when Chromium is unavailable for `reason`: the "Chromium unavailable"
    /// stand-in when Chromium failed to start, else the WebKit fallback.
    func chromiumUnavailable(_ tab: TabModel, url: URL?, reason: CEFUnavailableReason) -> BrowserEntry {
        guard reason.keepsChromiumTabsOutOfWebKit else {
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
        if let reason = browserTabs.cefUnavailable(), reason.keepsChromiumTabsOutOfWebKit {
            // Still no Chromium: wait again, on the address the person asked for.
            _ = chromiumUnavailable(tab, url: url ?? URL(string: tab.url), reason: reason)
        } else if let entry = browser(for: tab), let url, url.absoluteString != tab.url {
            entry.tab.load(url)
        }
        onBrowserReady?(key)
    }
}
