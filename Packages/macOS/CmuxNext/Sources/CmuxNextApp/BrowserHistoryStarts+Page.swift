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
                : !daemon.isLocal ? "skip-remote" : !daemon.supports(DaemonCapability.frontendBrowserHistory.rawValue) ? "skip-no-capability" : nil
        } else { "skip-address" }
        if let skip { outcomes[key] = skip }
        guard skip == nil, let url else { return nil }
        let page = cache.webKit.makeWebKitTab(id: BrowserTabID(rawValue: key), profile: cache.browserProfile?(key) ?? .default)
        hold(page, url: url, tabID: key)
        return cache.install(page, for: key)
    }

    /// `configuration` for restored Chromium tab `tab`, with the navigation state saved with its
    /// history when it was saved at the page's address (cx-il4fv): Chromium restores its back list
    /// and page state, and loads the address itself when it cannot. Tabs that open as before, as
    /// in `page`, keep `configuration`, and so does a history with a file outside the shown local
    /// page's folder (`BrowserHistoryWriter.keepsFileAccess(of:shown:)`, cx-5djb2).
    func chromium(_ tab: TabModel, _ configuration: BrowserTabConfiguration, cache: TabContentCache) async -> BrowserTabConfiguration {
        let service = cache.browserTabs, key = tab.id, daemon = service.daemon(for: tab)
        guard configuration.restoreState == nil, configuration.machineStore == nil, let url = configuration.initialURL,
              ["http", "https", "file"].contains(url.scheme?.lowercased() ?? ""), MachineBrowserRecord(url: url) == nil,
              tab.isFrontendOwned, !service.isIncognitoTab(key), !service.wasOpenedHere(tab), daemon.isLocal,
              daemon.supports(DaemonCapability.frontendBrowserHistory.rawValue) else { return configuration }
        // As for a WebKit page, a slow read makes the page at its address.
        let saved = await BrowserHistoryWriter.within(Self.budget, sleep: service.sleep) {
            await service.fetchHistory(daemon, tab.surface)
        }
        guard let state = BrowserHistoryWriter.restoreState(saved, at: url, engine: .cef),
              BrowserHistoryWriter.keepsFileAccess(of: saved, shown: url) else {
            outcomes[key] = saved == nil ? "address" : saved?.engineState == nil ? "address-no-state" : "address-file-access"
            return configuration
        }
        var restored = configuration
        restored.restoreState = state
        outcomes[key] = "engine"
        markEngineRestored(key)
        return restored
    }
}
