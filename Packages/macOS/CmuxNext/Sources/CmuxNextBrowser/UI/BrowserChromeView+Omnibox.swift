import Foundation

/// Extension keyword sessions (`chrome.omnibox`) between the omnibar and
/// the tab. Only Chromium tabs provide keywords.
extension BrowserChromeView {
    func bindOmniboxKeywords(_ tab: any BrowserTab) {
        let provider = tab as? any BrowserOmniboxKeywordProviding
        addressBar.keywordSource = { [weak provider] in provider?.omniboxKeywords() ?? [] }
        addressBar.keywordSuggest = { [weak provider] extensionID, text in
            await provider?.omniboxKeywordSuggestions(extensionID, text: text) ?? []
        }
        addressBar.onKeywordSession = { [weak provider] effect in
            switch effect {
            case .keywordStarted(let extensionID): provider?.omniboxKeywordStarted(extensionID)
            case .keywordEnded(let extensionID): provider?.omniboxKeywordEnded(extensionID)
            default: break
            }
        }
    }

    /// What an omnibar boundary loads: a commit loads here, another
    /// disposition opens elsewhere, Enter in a keyword session gives the
    /// extension the text.
    func performOmnibarEnd(_ event: OmnibarEvent) {
        let provider = tab as? any BrowserOmniboxKeywordProviding
        switch event {
        case .didBeginEditing:
            break
        case .didEndEditing(.commit(let url)):
            if loadOverride?(url) == true { return }
            tab.load(url)
        case .didEndEditing(.open(let url, let disposition)):
            onOpenURL.map { $0(url, disposition) } ?? tab.load(url)
        case .didEndEditing(.keyword(let extensionID, let text, let disposition)):
            provider?.omniboxKeywordEntered(extensionID, text: text, disposition: disposition)
        case .didEndEditing(.switchToTab(let key)):
            addressBar.suggestionEngine.revealTab(key)
        case .didEndEditing(.cancel), .didEndEditing(.blur):
            break
        }
    }
}
