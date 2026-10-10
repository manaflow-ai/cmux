import CmuxNextBrowser
import Observation

/// Every browser tab's media, for the toolbar's media hub (cx-6qwm.2):
/// the tabs whose page script reports media (`BrowserTabState.media`),
/// playing first. Reading `sessions` while observing tracks those tabs'
/// states and, through `tabsVersion`, tabs created later.
@Observable
final class BrowserMediaHub {
    /// Bumped as browser tabs are created (`BrowserToolbarHandlers.install`).
    private(set) var tabsVersion = 0

    func tabCreated() { tabsVersion &+= 1 }

    func sessions(in cache: TabContentCache) -> [(entry: BrowserEntry, media: BrowserMediaState)] {
        _ = tabsVersion
        return cache.browsers.values
            .compactMap { entry in entry.tab.state.media.map { (entry: entry, media: $0) } }
            .sorted { first, second in
                first.media.isPlaying != second.media.isPlaying
                    ? first.media.isPlaying : first.entry.tab.id.rawValue < second.entry.tab.id.rawValue
            }
    }

    /// What the media hub button shows.
    func toolbar(in cache: TabContentCache) -> BrowserToolbarMedia {
        let sessions = sessions(in: cache)
        return BrowserToolbarMedia(sessions: sessions.count, isPlaying: sessions.contains { $0.media.isPlaying })
    }
}
