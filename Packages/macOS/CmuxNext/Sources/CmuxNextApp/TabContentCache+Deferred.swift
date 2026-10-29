import CmuxNextBrowser
import Foundation
import CmuxNextDaemon

/// Restored pages that load nothing until they are started: after two quick unexpected ends in a row
/// (`defersRestoredPages`), and, while the app launches, those that do not show (Chrome's
/// session restore loads the visible tab first, chrome/browser/sessions/tab_loader.cc; the order is the
/// Chromium slot's ``CEFLaunchDeferral``, one deferral path, this one).
extension TabContentCache {
    /// The deferred page `tab` shows now, nil when its page is made now. `origin` is ``launchOrigin(of:)`` read in
    /// the same turn, which the page made now gets too: a page whose start was not deferred never waits for
    /// startup complete, so it never waits on the completion its visible pane holds open.
    func deferredPage(_ tab: TabModel, url: URL?, origin: BrowserTabOrigin) -> BrowserEntry? {
        let key = tab.id
        if defersRestoredPages, !startedDeferred.contains(key), !browserTabs.wasOpenedHere(tab) { return deferred(tab, url: url) }
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
        launchDeferredNodes[key] = nil
        browsers.removeValue(forKey: key)?.close()
        guard let tab = browserTabs.tabModel(key) else { return }
        if let entry = browser(for: tab), let url, url.absoluteString != tab.url { entry.tab.load(url) }
        onBrowserReady?(key)
    }
}
