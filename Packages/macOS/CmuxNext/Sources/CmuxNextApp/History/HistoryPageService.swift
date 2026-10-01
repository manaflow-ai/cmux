import AppKit
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextHistory
import Foundation

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
}

extension TabContentCache {
    /// The history page for a browser record whose URL is `cmux://history`
    /// (nil otherwise). Remote records never get here (`recordURL` keeps
    /// only web pages for them).
    func appPage(for tab: TabModel, url: URL?) -> BrowserEntry? {
        guard HistoryPageAddress.matches(url), let services = pageRequests.services else { return nil }
        let key = tab.id
        let engine: BrowserEngineKind = tab.browserEngine == BrowserEngineTag.cef.rawValue ? .cef : .webkit
        let page = HistoryPageTab(id: BrowserTabID(rawValue: key), engine: engine, profile: browserProfile?(key) ?? .default,
                                  source: services.historyPage)
        page.onNavigate = { [weak self] target in self?.leaveAppPage(key, to: target) }
        let entry = install(page, for: key)
        browserTabs.track(page, for: tab)
        return entry
    }

    /// History wiring of a new page: a reload is not a visit, that is a page
    /// for a tab its connection found already there (relaunch, daemon
    /// restart) or a page this process made for the tab before (hibernation
    /// wake, engine switch). A tab created later, by anyone, records its
    /// first visit. Typing `cmux://history` into the address bar shows the
    /// history page.
    func serveAppPages(_ entry: BrowserEntry, key: String) {
        guard let services = pageRequests.services else { return }
        let installedBefore = !services.history.installedPageKeys.insert(key).inserted
        if let tab = tabModel(key), installedBefore || services.machines.daemon(forTab: tab).store.restoredTabIDs.contains(key) {
            entry.chrome.markRestored(tab.url.flatMap(URL.init(string:)))
        }
        entry.chrome.loadOverride = { [weak self] url in
            guard HistoryPageAddress.matches(url), let self, let tab = tabModel(key) else { return false }
            showHistoryPage(in: tab)
            return true
        }
    }

    /// Replaces a page with the history page.
    func showHistoryPage(in tab: TabModel) {
        guard let services = pageRequests.services else { return }
        let key = tab.id
        let engine: BrowserEngineKind = tab.browserEngine == BrowserEngineTag.cef.rawValue ? .cef : .webkit
        let page = HistoryPageTab(id: BrowserTabID(rawValue: key), engine: engine, profile: browserProfile?(key) ?? .default,
                                  source: services.historyPage)
        page.onNavigate = { [weak self] target in self?.leaveAppPage(key, to: target) }
        swapPage(key, with: page)
    }

    /// The history page navigated to a web address: the tab becomes a real
    /// page of its record's engine (WebKit when Chromium cannot start).
    private func leaveAppPage(_ key: String, to url: URL) {
        let profile = browserProfile?(key) ?? .default
        let config = BrowserTabConfiguration(id: BrowserTabID(rawValue: key), profile: profile, initialURL: url)
        guard let tab = tabModel(key), tab.browserEngine == BrowserEngineTag.cef.rawValue, browserTabs.cefUnavailable() == nil else {
            return swapPage(key, with: webKit.makeWebKitTab(config))
        }
        // task-owner: one Chromium page creation; the tab swap is its only effect
        Task { [weak self] in
            guard let self else { return }
            let configured = await chromiumConfiguration(for: tab, base: config)
            if let page = try? await makeCEFTab(configured) {
                swapPage(key, with: page)
            } else {
                swapPage(key, with: webKit.makeWebKitTab(config))
            }
        }
    }
}
