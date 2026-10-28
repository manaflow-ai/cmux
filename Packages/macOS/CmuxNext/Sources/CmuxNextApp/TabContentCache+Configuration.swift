import CmuxNextBrowser
import CmuxNextDaemon

// A browser tab's record on any machine and its Chromium page's configuration.
extension TabContentCache {
    /// `base` with the remote-localhost store of `tab` (every Chromium page a
    /// tab gets goes through here, a hibernated page waking included). A
    /// failed proxy start leaves the page blank, never on this Mac's localhost.
    func chromiumConfiguration(for tab: TabModel?, base: BrowserTabConfiguration) async -> BrowserTabConfiguration {
        guard let tab, let configureBrowser else { return base }
        if let configured = await configureBrowser(tab, base.initialURL, base) { return configured }
        var blank = base
        blank.initialURL = nil
        blank.restoreState = nil
        blank.navigationGuard = .noLoopback
        return blank
    }

    /// The tab with durable id `key` on any machine.
    func tabModel(_ key: String) -> TabModel? {
        browserTabs.tabModel(key) ?? findTab?(key)
    }
}
