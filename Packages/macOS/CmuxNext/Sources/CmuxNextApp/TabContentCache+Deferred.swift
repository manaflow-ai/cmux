import CmuxNextBrowser
import CmuxNextBrowserHistory
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
        let entry = install(page, for: key)
        // The tab the page shows when Reload is pressed: a stand-in's page moves to its daemon tab
        // (`moveBrowser`), which rebinds the chrome's key but not this closure.
        // A plain Reload starts on the page it shows; only another address was typed.
        page.onStart = { [weak self, weak entry] requested in
            self?.retryChromium(entry?.chrome.addressBar.tabKey ?? key, typed: requested == url ? nil : requested)
        }
        entry.chrome.showNotice(BrowserEngineStrings.chromiumUnavailableRestoredTab)
        return entry
    }

    /// Reload, or an address typed, on a "Chromium unavailable" tab: the tab asks for its page again, on the
    /// typed address or else its record's current one. While Chromium still cannot serve it (in this process,
    /// until cmux restarts) it waits again, and a typed address goes to the tab's record so the restart opens it
    /// (never an incognito tab's: its URL stays in memory).
    private func retryChromium(_ key: String, typed: URL?) {
        browserTabs.untrack(key)
        browsers.removeValue(forKey: key)?.close()
        guard let tab = tabModel(key) else { return }  // a remote machine's tab included
        if let reason = browserTabs.cefUnavailable(), reason.keepsChromiumTabsOutOfWebKit {
            _ = chromiumUnavailable(tab, url: typed ?? tab.url.flatMap(URL.init(string:)), reason: reason)
            if let typed, typed.absoluteString != tab.url, tab.isFrontendOwned, !browserTabs.isIncognitoTab(key),
               !ProvisionalTab.isProvisional(surface: tab.surface) {
                let daemon = browserTabs.daemon(for: tab), update = browserTabs.update, surface = tab.surface
                // task-owner: one record write; the tab's next page writes over it
                Task { _ = await update(daemon, surface, BrowserRecordUpdate(url: typed.absoluteString, title: nil, favicon: .unchanged)) }
            }
        } else if let entry = browser(for: tab), let typed, typed.absoluteString != tab.url {
            entry.tab.load(typed)
        }
        onBrowserReady?(key)
    }
}
