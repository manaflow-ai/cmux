import Foundation

/// Extension keyword sessions (`chrome.omnibox`) between the omnibar and
/// its page, the same for a browser tab's toolbar (`BrowserChromeView`)
/// and a popup window (`OmnibarTabBinding`). Only Chromium pages provide
/// keywords; Enter reaches the page through `OmnibarEvent` `.keyword`.
extension AddressBarView {
    /// Offers `tab`'s extension keywords and tells its extensions when a
    /// session starts and ends.
    ///
    /// - Parameter tab: The page whose profile's extensions answer.
    public func bindKeywords(of tab: any BrowserTab) {
        let provider = tab as? any BrowserOmniboxKeywordProviding
        keywordSource = { [weak provider] in provider?.omniboxKeywords() ?? [] }
        keywordSuggest = { [weak provider] extensionID, text in
            await provider?.omniboxKeywordSuggestions(extensionID, text: text) ?? []
        }
        onKeywordSession = { [weak provider] effect in
            switch effect {
            case .keywordStarted(let extensionID): provider?.omniboxKeywordStarted(extensionID)
            case .keywordEnded(let extensionID): provider?.omniboxKeywordEnded(extensionID)
            default: break
            }
        }
    }
}
