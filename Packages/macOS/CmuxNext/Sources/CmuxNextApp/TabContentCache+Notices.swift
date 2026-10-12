import CmuxNextDaemon

extension TabContentCache {
    /// A notice for a tab whose page exists shows there at once
    /// (`BrowserTabService.showNotice`); otherwise the page takes it when
    /// it is made (`showPendingNotice`).
    func wireNotices() {
        browserTabs.showNotice = { [weak self] daemon, surface, text in
            guard let tab = daemon.store.tab(surface: surface), let entry = self?.browsers[tab.id] else { return false }
            entry.chrome.showNotice(text)
            return true
        }
    }

    /// Every page of a tab (web, app page, a late Chromium start, a
    /// session-local tab) shows the tab's pending notice once.
    func showPendingNotice(on entry: BrowserEntry, key: String) {
        guard let notice = browserTabs.takeNotice(forKey: key) ?? browserTabs.tabModel(key).flatMap(browserTabs.takeNotice(for:)) else { return }
        entry.chrome.showNotice(notice)
    }
}
