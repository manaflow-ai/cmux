public import CmuxBrowser
import CmuxCEF

/// chrome.omnibox keyword sessions of this page's profile (fork API 12).
///
/// Reference: cmux Next `CmuxNextBrowser/CEF/CEFTab+Omnibox.swift`.
extension CEFBrowserPage: BrowserPageOmniboxKeywordProviding {
    /// Read on every address bar change: cached per profile until
    /// extensions change.
    public func omniboxKeywords() -> [BrowserOmniboxKeyword] {
        browser.runtime.omniboxKeywords.keywords(browser: browser).map {
            BrowserOmniboxKeyword(extensionID: $0.extensionID, keyword: $0.keyword, name: $0.name,
                                  defaultDescription: $0.defaultDescription)
        }
    }

    public func omniboxKeywordStarted(_ extensionID: String) {
        browser.runtime.omniboxKeywords.started(browser: browser, extensionID: extensionID)
    }

    public func omniboxKeywordSuggestions(_ extensionID: String, text: String) async -> [BrowserOmniboxKeywordSuggestion] {
        let rows = await browser.runtime.omniboxKeywords.suggestions(browser: browser, extensionID: extensionID, text: text)
        return (rows ?? []).map {
            BrowserOmniboxKeywordSuggestion(extensionID: extensionID, content: $0.content, description: $0.description)
        }
    }

    public func omniboxKeywordEntered(_ extensionID: String, text: String, disposition: BrowserOmniboxKeywordDisposition) {
        browser.runtime.omniboxKeywords.entered(browser: browser, extensionID: extensionID, text: text,
                                                disposition: Self.omniboxDisposition(disposition))
    }

    public func omniboxKeywordEnded(_ extensionID: String) {
        browser.runtime.omniboxKeywords.cancelled(browser: browser, extensionID: extensionID)
    }

    /// `cmux_omnibox_event_t` ENTERED values.
    nonisolated static func omniboxDisposition(_ disposition: BrowserOmniboxKeywordDisposition) -> Int32 {
        switch disposition {
        case .currentTab: 0
        case .newForegroundTab: 1
        case .newBackgroundTab: 2
        }
    }
}
