import CmuxNextBrowser

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
    func resetIncognitoHistory() {
        incognitoMemory = IncognitoPageMemory()
    }
}
