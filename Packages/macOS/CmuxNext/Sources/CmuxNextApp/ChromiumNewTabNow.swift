import CmuxNextBrowser
import CmuxNextBrowserHistory
import CmuxNextDaemon
import CmuxNextRemoteLocalhostService
import Foundation

/// A Chromium tab on the New Tab page, or on any address in a tab opened here (a stand-in, a
/// link's tab), made in the turn that first shows it when Chromium already runs, so the tab's
/// toolbar is on its first frame instead of a frame later (perceived speed, Cmd-Shift-L, PL-cef-tab).
/// Anything else (a restored tab's address, whose saved history is read first; a proxied or
/// remote-localhost store; Chromium still starting) takes `TabContentCache.browser(for:)`'s
/// asynchronous path. The configuration is that path's (`configureBrowser`, then
/// `historyStarts`, which keeps a New Tab page and a tab opened here as they are) for a page that
/// needs nothing asynchronous.
struct ChromiumNewTabNow {
    let cache: TabContentCache

    func page(_ tab: TabModel, url: URL?) -> (any BrowserTab)? {
        guard let url, BrowserNewTabPage.isNewTabPage(url) || cache.browserTabs.wasOpenedHere(tab), cache.chromiumNow.runs() else { return nil }
        let key = tab.id, requests = cache.pageRequests
        var configuration = BrowserTabConfiguration(id: BrowserTabID(rawValue: key), profile: cache.browserProfile?(key) ?? .default, initialURL: url)
        guard requests.proxiedTabs.plan(for: key, url: url, base: configuration) == .notProxied else { return nil }
        if let remote = requests.services?.remoteLocalhost {
            guard case .profile(let navigationGuard) = RemoteLocalhostStorePlan.plan(route: remote.route(for: tab, engine: .cef), url: url) else { return nil }
            configuration.navigationGuard = navigationGuard
        }
        // Last: a reopened tab's closed history is claimed only by the page made here; every
        // bail-out above leaves it for the asynchronous path's page.
        configuration = requests.closedHistories.restoring(configuration, url: url, local: cache.browserTabs.daemon(for: tab).isLocal, tab: key)
        return cache.chromiumNow.make(configuration)
    }
}

/// How `ChromiumNewTabNow` makes a page in the current turn (`TabContentCache.chromiumNow`;
/// tests replace it per cache).
@MainActor struct ChromiumNow {
    /// True while Chromium runs, so a page can be made now.
    var runs: () -> Bool
    /// The page made now; nil if Chromium stopped since `runs`.
    var make: (BrowserTabConfiguration) -> (any BrowserTab)?

    init(_ cef: CEFEngine) {
        runs = { cef.isRunning }
        make = { cef.makeTabIfRunning($0) }
    }
}
