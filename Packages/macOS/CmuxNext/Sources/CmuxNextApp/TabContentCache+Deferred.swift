import CmuxNextBrowser
import Foundation
import CmuxNextDaemon
import os

/// Restored pages that load nothing until they are started: a page a run that ended early in a restart loop had
/// started (`crashedPages`), so it may be what ended it, and, while the app launches, those that do not show (Chrome's
/// session restore loads the visible tab first, chrome/browser/sessions/tab_loader.cc; the order is the
/// Chromium slot's ``CEFLaunchDeferral``, one deferral path, this one).
extension TabContentCache {
    /// The deferred page `tab` shows now, nil when its page is made now. `origin` is ``launchOrigin(of:)`` read in
    /// the same turn, which the page made now gets too: a page whose start was not deferred never waits for
    /// startup complete, so it never waits on the completion its visible pane holds open.
    func deferredPage(_ tab: TabModel, url: URL?, origin: BrowserTabOrigin) -> BrowserEntry? {
        let key = tab.id
        // A page a run that ended early in a restart loop had started waits for Reload (`crashedPages`).
        if !browserTabs.wasOpenedHere(tab), crashedPages.contains(key), !startedDeferred.contains(key) { return deferred(tab, url: url) }
        guard origin == .restoreHidden else { return nil }
        let entry = deferred(tab, url: url, notice: nil), page = entry.tab, tabNode = node(for: key)
        launchDeferredNodes[key] = tabNode  // its start when it shows lives with the node
        chromium.launchOrder.startHidden(when: tabNode) { [weak self, weak page] in
            if let page, self?.existingBrowser(key)?.tab === page { page.reload() }
        }
        return entry
    }

    /// The origin of a page `browser(for:)` makes now for `tab`: ``pageOrigin(of:)`` for a Chromium tab, else `.user`.
    func launchOrigin(of tab: TabModel) -> BrowserTabOrigin {
        tab.browserEngine == BrowserEngineTag.cef.rawValue ? pageOrigin(of: tab) : .user
    }

    /// Starts tab `key`'s launch-deferred page now, for a command, a script or an agent (``BrowserTabOrigin/automation``
    /// starts Chromium at once); false when its page is no launch-deferred one (a crash deferral waits for the person).
    func startLaunchDeferred(_ key: String) -> Bool {
        guard launchDeferredNodes[key] != nil, let page = browsers[key]?.tab as? DeferredBrowserTab else { return false }
        page.reload()
        return true
    }

    /// The origin of a page made now for `tab`: a restored tab's (in the daemon's launch snapshot, not opened
    /// here) by whether its tab node shows, else `.user`.
    func pageOrigin(of tab: TabModel) -> BrowserTabOrigin {
        guard !browserTabs.wasOpenedHere(tab), browserTabs.daemon(for: tab).store.restoredTabIDs.contains(tab.id) else { return .user }
        return chromium.launchOrder.restoredOrigin(isShown: node(for: tab.id).isVisible, wasStarted: startedDeferred.contains(tab.id))
    }

    /// A page that loads nothing until it is started (a reload, or the launch order); then the real page
    /// replaces it (same key, same record). `notice` shows on its chrome (by default why a crashed page waits); nil shows none.
    func deferred(_ tab: TabModel, url: URL?, notice: String? = CrashStrings.crashedPageNotice) -> BrowserEntry {
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
        launchDeferredNodes[key] = nil
        browsers.removeValue(forKey: key)?.close()
        guard let tab = tabModel(key) else { return }  // a remote machine's tab included
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
            self?.retryChromium(entry?.chrome.addressBar.tabKey ?? key, shown: requested, typed: requested != url)
        }
        entry.chrome.showNotice(BrowserEngineStrings.chromiumUnavailableRestoredTab)
        return entry
    }

    /// Reload, or an address typed, on a "Chromium unavailable" tab: the tab asks for its page again, on the
    /// typed address or else its record's current one (an incognito tab's record holds a placeholder, so it keeps
    /// the address it showed). While Chromium still cannot serve it (in this process,
    /// until cmux restarts) it waits again, and a typed address goes to the tab's record so the restart opens it
    /// (never an incognito tab's: its URL stays in memory).
    private func retryChromium(_ key: String, shown: URL?, typed isTyped: Bool) {
        browserTabs.untrack(key)
        browsers.removeValue(forKey: key)?.close()
        guard let tab = tabModel(key) else { return }  // a remote machine's tab included
        let incognito = browserTabs.isIncognitoTab(key)
        let typed = isTyped ? shown : nil
        let next = typed ?? (incognito ? shown : tab.url.flatMap(URL.init(string:)))
        if let reason = browserTabs.cefUnavailable(), reason.keepsChromiumTabsOutOfWebKit {
            _ = chromiumUnavailable(tab, url: next, reason: reason)
            // Every typed address, also one equal to the record's: an earlier typed write may still be on its way.
            if let typed { browserTabs.writeRecordURL(typed, for: tab) }
        } else if let entry = browser(for: tab), let typed, typed.absoluteString != tab.url {
            entry.tab.load(typed)
        }
        onBrowserReady?(key)
    }
}
