import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextRemoteLocalhostService
import Foundation

/// A Chromium tab on the New Tab page, made in the turn that first shows it when Chromium
/// already runs, so the tab's toolbar is on its first frame instead of a frame later (perceived
/// speed, Cmd-Shift-L). Anything else (another address, a proxied or remote-localhost store,
/// Chromium still starting) takes `TabContentCache.browser(for:)`'s asynchronous path. The
/// configuration is that path's (`configureBrowser`, then `historyStarts`, which keeps a New Tab
/// page as it is) for a page that needs nothing asynchronous.
struct ChromiumNewTabNow {
    /// Makes the page when Chromium runs, nil while it starts (a seam for tests).
    static var make: (CEFEngine, BrowserTabConfiguration) -> (any BrowserTab)? = { $0.makeTabIfRunning($1) }

    let cache: TabContentCache

    func page(_ tab: TabModel, url: URL?) -> (any BrowserTab)? {
        guard let url, BrowserNewTabPage.isNewTabPage(url) else { return nil }
        let key = tab.id, requests = cache.pageRequests
        var configuration = requests.closedHistories.restoring(
            BrowserTabConfiguration(id: BrowserTabID(rawValue: key), profile: cache.browserProfile?(key) ?? .default, initialURL: url),
            url: url, local: cache.browserTabs.daemon(for: tab).isLocal, tab: key)
        guard requests.proxiedTabs.plan(for: key, url: url, base: configuration) == .notProxied else { return nil }
        if let remote = requests.services?.remoteLocalhost {
            guard case .profile(let navigationGuard) = RemoteLocalhostStorePlan.plan(route: remote.route(for: tab, engine: .cef), url: url) else { return nil }
            configuration.navigationGuard = navigationGuard
        }
        return Self.make(cache.cef, configuration)
    }
}
