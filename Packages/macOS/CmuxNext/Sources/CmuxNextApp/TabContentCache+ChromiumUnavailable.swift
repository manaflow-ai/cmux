import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import os

/// A restored Chromium tab in a process whose Chromium failed to start is shown as "Chromium unavailable", with
/// Reload to try again; its URL never loads in WebKit. WebKit has none of Chromium's cookies, so a signed-in page
/// came back signed out (github.com/login?return_to=…) and looked like a reload (field log, 2026-10-26).
nonisolated enum ChromiumUnavailableRestore {
    /// Whether a Chromium record that cannot get Chromium for `reason` waits in place instead of loading in
    /// WebKit. Only a start failure: a build without Chromium (`notBundled`) or one still downloading it keeps
    /// the WebKit fallback and its notice, and a tab opened in this process chose its engine when it opened.
    static func holds(_ reason: CEFUnavailableReason, restored: Bool) -> Bool {
        guard restored, case .startFailed = reason else { return false }
        return true
    }
}

extension TabContentCache {
    private static let unavailableLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "browser.engine")

    /// The page of Chromium record `tab` when Chromium is unavailable for `reason`: the "Chromium unavailable"
    /// stand-in for a restored tab whose Chromium failed to start, else the WebKit fallback.
    func chromiumUnavailable(_ tab: TabModel, url: URL?, reason: CEFUnavailableReason) -> BrowserEntry {
        guard ChromiumUnavailableRestore.holds(reason, restored: !browserTabs.wasOpenedHere(tab)) else {
            return fallBack(tab, url: url, reason: reason)
        }
        let key = tab.id
        Self.unavailableLogger.notice("tab \(key, privacy: .public) waits: Chromium unavailable (\(reason.code, privacy: .public)); its page is not loaded in WebKit")
        let page = DeferredBrowserTab(id: BrowserTabID(rawValue: key), engine: .cef, url: url, title: tab.title.isEmpty ? nil : tab.title)
        page.onStart = { [weak self] url in self?.retryChromium(key, url: url) }
        let entry = install(page, for: key)
        entry.chrome.showNotice(BrowserEngineStrings.chromiumUnavailableRestoredTab)
        return entry
    }

    /// Reload (or an address) on a "Chromium unavailable" tab: the tab asks for its page again, which waits again
    /// while Chromium still cannot start.
    private func retryChromium(_ key: String, url: URL?) {
        browsers.removeValue(forKey: key)?.close()
        guard let tab = browserTabs.tabModel(key) else { return }
        if let entry = browser(for: tab), !(entry.tab is DeferredBrowserTab), let url, url.absoluteString != tab.url { entry.tab.load(url) }
        onBrowserReady?(key)
    }
}
