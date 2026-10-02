import Foundation

/// Chromium's back/forward entries for the Back and Forward button menus
/// (plans/cmux-next/history.md 4.1), from fork API 14
/// (`cmux_shim_tab_navigation_entries`, `cmux_shim_tab_go_to_entry`).
/// An older fork lists nothing, so its buttons show no menu.
extension CEFTab: BrowserBackForwardListing {
    static let backForwardListForkAPI: Int32 = 14

    /// Chromium's list with the entries saved before a relaunch around it.
    public func navigationList() -> BrowserNavigationList? {
        let native = nativeNavigationList()
        guard let saved = restored.history, let url = state.url else { return native }
        return saved.merged(with: native, shown: BrowserNavigationEntry(url: url, title: state.title))
    }

    /// Chromium's own back/forward list (fork API 14), nil before it.
    func nativeNavigationList() -> BrowserNavigationList? {
        guard let browserID, let shim = runtime.shim, runtime.forkAPIVersion >= Self.backForwardListForkAPI,
              let json = shim.takeString(shim.tabNavigationEntries(browserID)),
              let parsed = CEFNavigationEntries(json: json), !parsed.entries.isEmpty else { return nil }
        let entries = parsed.entries.map { entry in
            BrowserNavigationEntry(url: URL(string: entry.url), title: entry.title.isEmpty ? nil : entry.title)
        }
        return BrowserNavigationList(entries: entries, current: parsed.currentIndex)
    }

    /// `offset` counts in `navigationList()` (`CEFRestoredSession.goToEntry`).
    @discardableResult
    public func goToEntry(offset: Int) -> Bool {
        restored.history == nil ? goToNativeEntry(offset: offset) : restored.goToEntry(offset: offset)
    }

    func goToNativeEntry(offset: Int) -> Bool {
        guard let browserID, let shim = runtime.shim, runtime.forkAPIVersion >= Self.backForwardListForkAPI,
              let offset = Int32(exactly: offset) else { return false }
        return shim.tabGoToEntry(browserID, offset) == 1
    }
}
