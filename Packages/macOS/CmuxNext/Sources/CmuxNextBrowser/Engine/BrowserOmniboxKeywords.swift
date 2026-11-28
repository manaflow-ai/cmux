public import Foundation

/// A tab whose extensions can take omnibar input (`chrome.omnibox`): the
/// Chromium tab. The chrome feeds keyword sessions through this.
@MainActor public protocol BrowserOmniboxKeywordProviding: AnyObject {
    /// Keywords of the enabled extensions of the tab's profile.
    func omniboxKeywords() -> [OmnibarKeyword]
    /// A session started (`onInputStarted`).
    func omniboxKeywordStarted(_ extensionID: String)
    /// The session's text changed (`onInputChanged`); the extension's rows.
    func omniboxKeywordSuggestions(_ extensionID: String, text: String) async -> [BrowserSuggestion]
    /// Enter (`onInputEntered`).
    func omniboxKeywordEntered(_ extensionID: String, text: String, disposition: OmnibarDisposition)
    /// The session ended without Enter (`onInputCancelled`).
    func omniboxKeywordEnded(_ extensionID: String)
}
