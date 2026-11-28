import CmuxNextBrowser
import Foundation
import CmuxNextDaemon

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
