import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import Observation

/// What incognito pages keep in memory for the omnibar: their own history
/// and suggestions, never mixed with the normal ones. The history has no
/// persistence, so its index lives in memory only. Bookmark rows come from
/// the default profile (plans/cmux-next/bookmarks.md section 2).
final class IncognitoPageMemory {
    let history = InMemoryBrowserHistory()
    let suggestions: OmniboxSuggestionEngine
    private var announced = false

    /// The engine, handed to `announce` (the bookmark feed of
    /// `onSuggestionEngineCreated`) the first time only.
    func announcedSuggestions(_ announce: (OmniboxSuggestionEngine) -> Void) -> OmniboxSuggestionEngine {
        if !announced {
            announced = true
            announce(suggestions)
        }
        return suggestions
    }

    init() {
        suggestions = OmniboxSuggestionEngine(history: history)
    }
}

extension TabContentCache {
    /// Forgets what incognito pages kept in memory (the session ended).
    /// Title, URL and favicon of incognito tab `key` for the tab strip: its live page, else its start URL (never the
    /// daemon record). Observes this tab's page install only, never every page install (TYPING FIX 2).
    func incognitoDisplay(_ tab: TabModel) -> (title: String?, url: String?) {
        _ = pageInstalls.generation(of: tab.id)
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
