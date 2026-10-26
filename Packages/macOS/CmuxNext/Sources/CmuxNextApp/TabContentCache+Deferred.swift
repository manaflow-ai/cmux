import CmuxNextBrowser
import Foundation
import CmuxNextDaemon

/// Restored pages that load nothing until they are started: after two quick unexpected ends in a row
/// (`defersRestoredPages`), and, while the app launches, those that do not show (p08-startup-040: Chrome's
/// session restore loads the visible tab first, chrome/browser/sessions/tab_loader.cc; the order is the
/// Chromium slot's ``CEFLaunchDeferral``, one deferral path, this one).
extension TabContentCache {
    /// The deferred page `tab` shows now, nil when its page is made now.
    func deferredPage(_ tab: TabModel, url: URL?) -> BrowserEntry? {
        let key = tab.id
        if defersRestoredPages, !startedDeferred.contains(key), !browserTabs.wasOpenedHere(tab) { return deferred(tab, url: url) }
        guard tab.browserEngine == BrowserEngineTag.cef.rawValue, pageOrigin(of: tab) == .restoreHidden else { return nil }
        let entry = deferred(tab, url: url, notice: nil), page = entry.tab
        chromium.launchOrder.startHidden(when: node(for: key)) { [weak self, weak page] in
            if let page, self?.existingBrowser(key)?.tab === page { page.reload() }
        }
        return entry
    }

    /// The origin of a page made now for `tab`: a restored tab's (in the daemon's launch snapshot, not opened
    /// here) by whether its tab node shows, else `.user`.
    func pageOrigin(of tab: TabModel) -> BrowserTabOrigin {
        guard !browserTabs.wasOpenedHere(tab), browserTabs.daemon(for: tab).store.restoredTabIDs.contains(tab.id) else { return .user }
        return chromium.launchOrder.restoredOrigin(isShown: node(for: tab.id).isVisible, wasStarted: startedDeferred.contains(tab.id))
    }

    /// A page that loads nothing until it is started (a reload, or the launch order); then the real page
    /// replaces it (same key, same record). `notice` shows on its chrome; nil shows none.
    func deferred(_ tab: TabModel, url: URL?, notice: String? = CrashStrings.deferredPageNotice) -> BrowserEntry {
        let key = tab.id
        let engine: BrowserEngineKind = tab.browserEngine == BrowserEngineTag.cef.rawValue ? .cef : .webkit
        let page = DeferredBrowserTab(id: BrowserTabID(rawValue: key), engine: engine, url: url, title: tab.title.isEmpty ? nil : tab.title)
        page.onStart = { [weak self] url in self?.startDeferred(key, url: url) }
        let entry = install(page, for: key)
        if let notice { entry.chrome.showNotice(notice) }
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
