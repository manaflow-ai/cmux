import Foundation

/// Extension omnibox keywords of a fake page: `omniboxKeywordsFake` are
/// offered, Enter is recorded in `enteredOmniboxKeywords`.
extension MockBrowserTab: BrowserOmniboxKeywordProviding {
    public func omniboxKeywords() -> [OmnibarKeyword] { omniboxKeywordsFake }
    public func omniboxKeywordStarted(_ extensionID: String) {}
    public func omniboxKeywordSuggestions(_ extensionID: String, text: String) async -> [BrowserSuggestion] { [] }
    public func omniboxKeywordEntered(_ extensionID: String, text: String, disposition: OmnibarDisposition) {
        enteredOmniboxKeywords.append((extensionID, text))
    }
    public func omniboxKeywordEnded(_ extensionID: String) {}
}
