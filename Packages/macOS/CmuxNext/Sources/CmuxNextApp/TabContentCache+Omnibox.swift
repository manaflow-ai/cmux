import CmuxNextBrowser
import Foundation

/// The omnibar suggestion engines (plans/cmux-next/omnibar-suggestions.md):
/// one per browser profile over that profile's history, plus the
/// incognito one; each offers the profile's open tabs as Switch to Tab rows.
extension TabContentCache {
    func makeSuggestionEngine(history: InMemoryBrowserHistory, profile: BrowserProfileID) -> OmniboxSuggestionEngine {
        let engine = OmniboxSuggestionEngine(history: history)
        engine.openTabs = { [weak self] in self?.openTabRows(incognito: false, profile: profile) ?? [] }
        engine.revealTab = { [weak self] key in self?.onRevealTab?(key) }
        onSuggestionEngineCreated?(engine, profile)
        return engine
    }

    /// The incognito engine, offering incognito tabs only.
    func incognitoSuggestions(_ memory: IncognitoPageMemory) -> OmniboxSuggestionEngine {
        let engine = memory.suggestions
        engine.openTabs = { [weak self] in self?.openTabRows(incognito: true, profile: .default) ?? [] }
        engine.revealTab = { [weak self] key in self?.onRevealTab?(key) }
        return engine
    }

    /// Live pages of one profile (or of incognito) with a loaded URL.
    func openTabRows(incognito: Bool, profile: BrowserProfileID) -> [OmniboxTabRow] {
        browsers.compactMap { key, entry in
            let page = entry.tab
            let offTheRecord = OffTheRecordProfiles.shared.isOffTheRecord(page.profileID)
            guard offTheRecord == incognito, incognito || page.profileID == profile,
                  let url = page.state.url, !BrowserNewTabPage.isNewTabPage(url) else { return nil }
            return OmniboxTabRow(key: key, url: url, title: page.state.title)
        }.sorted { $0.key < $1.key }
    }
}
