import CmuxNextDaemon
import CmuxNextDesign

/// The tab strip's attention dot for a background browser tab whose title
/// changes (cx-d0d.57), as Firefox marks one: a page that shows news in its
/// title ("(3) Inbox") gets the unread dot until the tab is viewed. Only a
/// change from a title already shown at the same URL counts, so a page's
/// first title (a tab opened in the background) marks nothing. Plain state,
/// read and written while the strip snapshot is built from the tab records:
/// the snapshot already re-runs when a title or the selection changes.
@MainActor
final class BrowserTitleAttention {
    /// The last title each background tab showed, with its URL.
    private var seen: [String: (url: String?, title: String)] = [:]
    private var marked: Set<String> = []

    /// Whether browser tab `tab` shows the attention dot; never while
    /// Settings hides attention on tabs. A title that comes while its live
    /// page in `cache` loads (a load or reload at the same URL) is the
    /// page's, not news; that state is read only when the title changed, so
    /// the snapshot does not follow every page state change.
    func marks(_ tab: TabModel, selected: Bool, in cache: TabContentCache) -> Bool {
        let key = tab.id
        guard DesignSettings.shared.attention.showsOnTab else {
            (seen[key], marked) = (nil, [])
            return false
        }
        guard !selected, !tab.title.isEmpty else {
            if selected { marked.remove(key) }
            seen[key] = nil
            return marked.contains(key)
        }
        if let last = seen[key], last.url == tab.url, last.title != tab.title,
           cache.existingBrowser(key)?.tab.state.isLoading != true { marked.insert(key) }
        seen[key] = (tab.url, tab.title)
        return marked.contains(key)
    }
}
