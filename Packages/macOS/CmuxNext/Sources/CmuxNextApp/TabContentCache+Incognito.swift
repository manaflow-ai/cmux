import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import Observation

/// Bumped whenever a page is installed, so tab strips that show a live page
/// instead of its daemon record (incognito tabs) re-render once it exists.
@Observable
final class PageInstallCounter {
    private(set) var revision = 0
    func bump() { revision &+= 1 }
}

/// What incognito pages keep in memory for the omnibar: their own history
/// and suggestions, never mixed with the normal ones.
struct IncognitoPageMemory {
    let history = InMemoryBrowserHistory()
    let suggestions: OmniboxSuggestionEngine

    init() {
        suggestions = OmniboxSuggestionEngine(providers: [HistorySuggestionProvider(store: history)])
    }
}

extension TabContentCache {
    /// Forgets what incognito pages kept in memory (the session ended).
    /// Title, URL and favicon of incognito tab `key` for the tab strip:
    /// its live page, else its start URL (never the daemon record).
    func incognitoDisplay(_ tab: TabModel) -> (title: String?, url: String?) {
        _ = pageInstalls.revision
        guard let page = browsers[tab.id]?.tab.state else {
            let start = browserTabs.startURL(for: tab)
            return (start.flatMap(URL.init(string:))?.host(), start)
        }
        return (Self.incognitoTitle(page.title, url: page.url), page.url?.absoluteString)
    }

    /// The tab title of an incognito page: its title, else its host; nil
    /// (the caller's "New Tab") for a blank page.
    static func incognitoTitle(_ title: String?, url: URL?) -> String? {
        let blank = url == nil || url?.absoluteString == "about:blank"
        if blank, title == nil || title == "about:blank" || title?.isEmpty == true { return nil }
        return title.flatMap { $0.isEmpty ? nil : $0 } ?? url?.host()
    }

    func resetIncognitoHistory() {
        incognitoMemory = IncognitoPageMemory()
        browserTabs.forgetIncognitoURLs()
    }
}
