import CmuxNextBrowser
import CmuxNextBrowserHistory
import CmuxNextDaemon
import Foundation

extension BrowserHistoryStarts {
    /// The blank page for restored tab `tab` at `url`, waiting for its saved history; nil when
    /// the tab opens as before: a page the user opened now, a remote machine's tab, a
    /// proxied or machine page, an incognito tab, or a page that is neither a web page nor a
    /// local file.
    func page(_ tab: TabModel, url: URL?, cache: TabContentCache) -> BrowserEntry? {
        let service = cache.browserTabs, key = tab.id, daemon = service.daemon(for: tab)
        let skip: String? = if let url, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? ""), MachineBrowserRecord(url: url) == nil {
            cache.pageRequests.proxiedTabs.isProxied(key) || !tab.isFrontendOwned || service.isIncognitoTab(key) ? "skip-page-kind"
                : service.writers[key] != nil ? "skip-tracked" : service.wasOpenedHere(tab) ? "skip-opened-here"
                : !daemon.isLocal ? "skip-remote" : !daemon.supports(DaemonCapabilities.shared.frontendBrowserHistory) ? "skip-no-capability" : nil
        } else { "skip-address" }
        if let skip { outcomes[key] = skip }
        guard skip == nil, let url else { return nil }
        let page = cache.webKit.makeWebKitTab(id: BrowserTabID(rawValue: key), profile: cache.browserProfile?(key) ?? .default)
        hold(page, url: url, tabID: key)
        return cache.install(page, for: key)
    }
}
