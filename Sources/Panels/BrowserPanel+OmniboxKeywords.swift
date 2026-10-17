import CmuxBrowser

/// chrome.omnibox keyword sessions in a Chromium panel's address bar: typing
/// an extension's keyword and a space sends the text after it to the
/// extension (`onInputStarted`, `onInputChanged`), its suggestions become the
/// address bar's rows, and Return hands the text to the extension
/// (`onInputEntered`) instead of loading it. A WebKit panel has no keyword
/// provider, so none of this runs for it.
///
/// Reference: cmux Next `CmuxNextApp/TabContentCache+Omnibox.swift`,
/// `CmuxNextBrowser/Omnibox/OmnibarReducer+Keyword.swift`.
extension BrowserPanel {
    /// The page's extensions, for a Chromium panel only.
    var omniboxKeywordProvider: (any BrowserPageOmniboxKeywordProviding)? {
        guard engineKind == .chromium else { return nil }
        return enginePage as? any BrowserPageOmniboxKeywordProviding
    }
}

/// One address bar's keyword session: which extension has it open and the
/// session events that follow from the text.
@MainActor
final class ChromiumOmniboxKeywordSession {
    private var state = BrowserOmniboxKeywordSessionState()
    private weak var provider: (any BrowserPageOmniboxKeywordProviding)?

    /// The extension whose session is open.
    var activeExtensionID: String? { state.activeExtensionID }

    /// The session `text` opens in `provider`'s extensions (nil: none),
    /// after starting it or cancelling the previous one as needed.
    func update(text: String, provider: (any BrowserPageOmniboxKeywordProviding)?)
        -> (keyword: BrowserOmniboxKeyword, rest: String)? {
        let match = provider.flatMap { BrowserOmniboxKeyword.match(text, in: $0.omniboxKeywords()) }
        let previous = self.provider
        for change in state.update(match?.keyword.extensionID) {
            switch change {
            case .cancelled(let extensionID): previous?.omniboxKeywordEnded(extensionID)
            case .started(let extensionID): provider?.omniboxKeywordStarted(extensionID)
            }
        }
        self.provider = match == nil ? nil : provider
        return match
    }

    /// The address bar closed without Return: cancels an open session.
    func end() {
        _ = update(text: "", provider: nil)
    }

    /// Return on `text`: when it is a keyword session, the text after the
    /// keyword goes to the extension and the panel loads nothing. True
    /// when handled.
    func enter(text: String, provider: (any BrowserPageOmniboxKeywordProviding)?) -> Bool {
        guard let match = update(text: text, provider: provider), let provider else { return false }
        return enter(extensionID: match.keyword.extensionID, content: match.rest, provider: provider)
    }

    /// A chosen suggestion row of `extensionID`.
    func enter(extensionID: String, content: String, provider: (any BrowserPageOmniboxKeywordProviding)?) -> Bool {
        guard let provider else { return false }
        if state.activeExtensionID != extensionID {
            for case .cancelled(let previous) in state.update(extensionID) { self.provider?.omniboxKeywordEnded(previous) }
            provider.omniboxKeywordStarted(extensionID)
        }
        provider.omniboxKeywordEntered(extensionID, text: content, disposition: .currentTab)
        state.entered()
        self.provider = nil
        return true
    }
}
