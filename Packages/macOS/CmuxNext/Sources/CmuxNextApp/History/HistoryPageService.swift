import AppKit
import CmuxNextAgentActivity
import CmuxNextBookmarks
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextBrowserAutomation
import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextRemoteView
import Foundation
import os
#if DEBUG
import CmuxNextRemoteBrowser
#endif

/// Opens `cmux://history` and serves its data (plans/cmux-next/history.md
/// 5.1). The page is a browser tab whose record URL is `cmux://history`, so
/// it survives relaunch like any tab.
final class HistoryPageService: HistoryPageSource {
    private unowned let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    /// Selects the active window's history tab, else opens one beside the
    /// focused tab (or in it, when that tab is a blank page).
    func open() {
        guard let window = services.windows.active else { return services.registry.refuse(RefusalStrings.noWindowOpen) }
        for pane in window.content?.panes.values.map({ $0 }) ?? [] {
            if let tab = pane.pane.tabs.first(where: { HistoryPageAddress.matches($0.url.flatMap(URL.init(string:))) }) {
                pane.select(StripTabID(tab.id))
                return
            }
        }
        guard let pane = window.focusedPane else { return }
        if let tab = pane.selectedTab, tab.kind == .browser, let page = services.cache.existingBrowser(tab.id)?.tab,
           BrowserNewTabPage.isNewTabPage(page.state.url) {
            services.cache.showHistoryPage(in: tab)
            return
        }
        pane.newBrowserTab(url: HistoryPageAddress.url)
    }

    // MARK: HistoryPageSource

    func entries(_ query: HistoryQuery) async -> [HistoryEntry] {
        await services.history.entries(query)
    }

    func open(_ entry: HistoryEntry, newTab: Bool) {
        HistoryRestorer(services: services).open(entry, newTab: newTab)
    }

    func remove(_ entry: HistoryEntry) {
        services.history.remove(entry)
    }

    func removeSite(of entry: HistoryEntry) {
        guard case .page(let url, _) = entry.payload, let host = URL(string: url)?.host() else { return }
        services.history.removePages(host: host)
    }

    func clear(range: HistoryRange) {
        services.history.clear(kinds: [], range: range)
    }

    func copy(_ text: String) {
        HistoryRestorer(services: services).copy(text)
    }

    /// The app's cookie backups (WebKit tabs' agent clears), read off the
    /// main actor: the files are decrypted with the Keychain key.
    func cookieBackups() async -> [HistoryCookieBackup] {
        guard let backups = services.browserHost?.driver.cookieBackups else { return [] }
        return await Task.detached {
            backups.pruneExpired()
            return backups.summaries().map { HistoryCookieBackup(id: $0.restoreID, site: $0.site, createdAt: $0.createdAt) }
        }.value
    }

    /// The person confirmed: the backups go for good (an agent never gets here).
    func deleteCookieBackups(_ ids: [String]) async {
        guard let backups = services.browserHost?.driver.cookieBackups else { return }
        let deleted = await Task.detached { ids.filter { (try? backups.remove($0)) != nil }.count }.value
        Self.logger.info("deleted \(deleted, privacy: .public) of \(ids.count, privacy: .public) cookie backups at the person's request")
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cookie-backups")
}

extension TabContentCache {
    /// The native page for a browser record whose URL is `cmux://history`,
    /// `cmux://bookmarks`, `cmux://agent-activity` or `cmux://remote-view`
    /// (nil otherwise). Remote records never get here
    /// (`recordURL` keeps only web pages for them).
    func appPage(for tab: TabModel, url: URL?) -> BrowserEntry? {
        guard let page = makeAppPage(url, for: tab) else { return nil }
        let entry = install(page, for: tab.id)
        browserTabs.track(page, for: tab)
        return entry
    }

    /// History wiring of a new page: a reload is not a visit, that is a page
    /// for a tab its connection found already there (relaunch, daemon
    /// restart) or a page this process made for the tab before (hibernation
    /// wake, engine switch). A tab created later, by anyone, records its
    /// first visit. Typing an app page address (`cmux://history`,
    /// `cmux://bookmarks`, or `chrome://history`, `chrome://bookmarks`:
    /// `routedChromiumPage`) into the address bar shows that page.
    func serveAppPages(_ entry: BrowserEntry, key: String) {
        guard let services = pageRequests.services else { return }
        let installedBefore = !services.history.installedPageKeys.insert(key).inserted
        if let tab = tabModel(key), installedBefore || services.machines.daemon(forTab: tab).store.restoredTabIDs.contains(key) {
            entry.chrome.markRestored(tab.url.flatMap(URL.init(string:)))
        }
        entry.chrome.loadOverride = { [weak self, weak chrome = entry.chrome] typed in
            // chrome://history shows cmux's page; chrome://settings opens Settings and nothing loads here.
            guard let url = services.routedChromiumPage(typed) else {
                chrome?.addressBar.showPageURL()
                return true
            }
            guard Self.isAppPage(url) else { return false }
            // Never load a cmux page address in the engine (WebKit cancels it without a word).
            guard let self, let tab = tabModel(key) else { return true }
            // Typed in the address bar (or a bookmark a person opened).
            if RemoteViewTabRecord.matches(url) { services.remoteViewPages.confirm(key, url: url) }
            showAppPage(url, in: tab)
            return true
        }
    }

    /// Replaces a page with the history page.
    func showHistoryPage(in tab: TabModel) { showAppPage(HistoryPageAddress.url, in: tab) }

    /// Replaces a page with the app page at `url`.
    func showAppPage(_ url: URL, in tab: TabModel) {
        guard let page = makeAppPage(url, for: tab) else { return }
        swapPage(tab.id, with: page)
    }

    static func isAppPage(_ url: URL?) -> Bool {
        HistoryPageAddress.matches(url) || BookmarkPageAddress.matches(url) || AgentActivityPageAddress.matches(url)
            || RemoteViewTabRecord.matches(url) || isRemoteBrowserPage(url) || MachineBrowserRecord.matches(url)
    }

    /// A development remote tab record (`cmux://remote-browser`).
    static func isRemoteBrowserPage(_ url: URL?) -> Bool {
        #if DEBUG
        RemoteBrowserTabRecord.matches(url)
        #else
        false
        #endif
    }

    private func makeAppPage(_ url: URL?, for tab: TabModel) -> (any BrowserTab)? {
        guard Self.isAppPage(url), let services = pageRequests.services else { return nil }
        let key = tab.id
        let engine: BrowserEngineKind = tab.browserEngine == BrowserEngineTag.cef.rawValue ? .cef : .webkit
        let profile = browserProfile?(key) ?? .default
        // A machine's own record (cx-2cob), before the loopback dev record of the same host.
        if let record = url.flatMap(MachineBrowserRecord.init(url:)) {
            return MachineBrowserPages(cache: self).makePage(record, key: key, engine: engine, profile: profile)
        }
        #if DEBUG
        if let url, RemoteBrowserTabRecord.matches(url) {
            return RemoteBrowserPages.makePage(url: url, key: key, profile: profile, services: services)
        }
        #endif
        if AgentActivityPageAddress.matches(url) {
            let page = services.agentActivityPage.makePage(key: key, engine: engine, profile: profile)
            page.onNavigate = { [weak self] target in self?.leaveAppPage(key, to: target) }
            return page
        }
        if let url, RemoteViewTabRecord.matches(url) {
            let pages = services.remoteViewPages
            let source = pages.source(for: key, url: url, isLocal: services.machines.daemon(forTab: tab).isLocal)
            let decision = RemoteViewTabPolicy().decide(record: RemoteViewTabRecord(url: url), source: source)
            let page = RemoteViewPageTab(
                id: BrowserTabID(rawValue: key), engine: engine, profile: profile, url: url, decision: decision,
                closeTab: { [weak self] in self?.pageRequests.closeTab(key) },
                connect: { [weak self] confirmedURL in
                    // The Connect button: a person confirmed this record (view mode).
                    pages.confirm(key, url: confirmedURL)
                    guard let self, let tab = tabModel(key) else { return }
                    showAppPage(confirmedURL, in: tab)
                })
            page.onNavigate = { [weak self] target in
                pages.forget(key)
                self?.leaveAppPage(key, to: target)
            }
            return page
        }
        if BookmarkPageAddress.matches(url) {
            let page = services.bookmarkPages.makePage(key: key, engine: engine, profile: profile)
            page.onNavigate = { [weak self] target in self?.leaveAppPage(key, to: target) }
            return page
        }
        let page = HistoryPageTab(id: BrowserTabID(rawValue: key), engine: engine, profile: profile, source: services.historyPage,
                                  webPage: PageFactory(services: services).historyWebPage())
        page.onNavigate = { [weak self] target in self?.leaveAppPage(key, to: target) }
        page.webPage?.onOpenExternal = { [weak self] target in self?.leaveAppPage(key, to: target) }
        return page
    }

    /// The history page navigated to a web address: the tab becomes a real
    /// page of its record's engine (WebKit when Chromium cannot start).
    func leaveAppPage(_ key: String, to url: URL) {
        let profile = browserProfile?(key) ?? .default
        let config = BrowserTabConfiguration(id: BrowserTabID(rawValue: key), profile: profile, initialURL: url)
        guard let tab = tabModel(key), tab.browserEngine == BrowserEngineTag.cef.rawValue, browserTabs.cefUnavailable() == nil else {
            return swapPage(key, with: unproxiedWebKitPage(config))
        }
        // task-owner: one Chromium page creation; the tab swap is its only effect
        Task { [weak self] in
            guard let self else { return }
            let configured = await chromiumConfiguration(for: tab, base: config)
            if let page = try? await makeCEFTab(configured) {
                swapPage(key, with: page)
            } else {
                swapPage(key, with: unproxiedWebKitPage(config))
            }
        }
    }

    /// A WebKit page for `config`; a proxied tab's page stays blank (its URL is a remote
    /// machine's localhost, which WebKit would load from this Mac).
    private func unproxiedWebKitPage(_ config: BrowserTabConfiguration) -> WebKitTab {
        webKit.makeWebKitTab(id: config.id, profile: config.profile,
                             initialURL: pageRequests.proxiedTabs.isProxied(config.id.rawValue) ? nil : config.initialURL)
    }
}
