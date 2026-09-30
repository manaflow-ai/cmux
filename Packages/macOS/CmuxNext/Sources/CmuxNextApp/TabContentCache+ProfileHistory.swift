import CmuxNextBrowser

/// Omnibar history per browser profile (plans/cmux-next/data-model.md 5):
/// a page visited in one profile never shows as a suggestion in another.
extension TabContentCache {
    struct ProfileHistory {
        let history: InMemoryBrowserHistory
        let suggestions: OmniboxSuggestionEngine
    }

    /// `profile`'s history (the default profile's is `history`).
    func history(for profile: BrowserProfileID) -> InMemoryBrowserHistory {
        profile == .default ? history : profileHistory(profile).history
    }

    func suggestions(for profile: BrowserProfileID) -> OmniboxSuggestionEngine {
        profile == .default ? suggestionEngine : profileHistory(profile).suggestions
    }

    /// Forgets a deleted profile's history.
    func dropHistory(for profile: BrowserProfileID?) {
        guard let profile, profile != .default else { return }
        profileHistories[profile] = nil
    }

    private func profileHistory(_ profile: BrowserProfileID) -> ProfileHistory {
        if let existing = profileHistories[profile] { return existing }
        let history = InMemoryBrowserHistory()
        let made = ProfileHistory(history: history, suggestions: OmniboxSuggestionEngine(providers: [HistorySuggestionProvider(store: history)]))
        profileHistories[profile] = made
        return made
    }
}
