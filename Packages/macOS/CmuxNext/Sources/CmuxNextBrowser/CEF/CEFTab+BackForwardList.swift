import Foundation

/// Chromium's back/forward entries for the Back and Forward button menus
/// (plans/cmux-next/history.md 4.1), from fork API 14
/// (`cmux_shim_tab_navigation_entries`, `cmux_shim_tab_go_to_entry`).
/// An older fork lists nothing, so its buttons show no menu.
extension CEFTab: BrowserBackForwardListing {
    static let backForwardListForkAPI: Int32 = 14

    public func navigationList() -> BrowserNavigationList? {
        guard let browserID, let shim = runtime.shim, runtime.forkAPIVersion >= Self.backForwardListForkAPI,
              let json = shim.takeString(shim.tabNavigationEntries(browserID)),
              let parsed = CEFNavigationEntries(json: json), !parsed.entries.isEmpty else { return nil }
        let entries = parsed.entries.map { entry in
            BrowserNavigationEntry(url: URL(string: entry.url), title: entry.title.isEmpty ? nil : entry.title)
        }
        return BrowserNavigationList(entries: entries, current: parsed.currentIndex)
    }

    @discardableResult
    public func goToEntry(offset: Int) -> Bool {
        guard let browserID, let shim = runtime.shim, runtime.forkAPIVersion >= Self.backForwardListForkAPI,
              let offset = Int32(exactly: offset) else { return false }
        return shim.tabGoToEntry(browserID, offset) == 1
    }
}
