import Foundation

/// The omnibar's address and the end of an edit for the tab.
extension BrowserChromeView {
    /// The address the omnibar shows for `state`: the page's URL, or the
    /// address that failed to load while its error page shows. Chrome keeps
    /// the failed address in the omnibox (the error page commits it), so
    /// the bar never names the previous page over an error for another
    /// one; WebKit moves its URL back to the old page when a load fails.
    nonisolated static func omnibarURL(for state: BrowserTabState) -> URL? {
        if state.processExit == nil, let failing = state.loadError?.failingURL { return failing }
        return state.url
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
            // The person's own navigation replaces the address the page slept on.
            wakingAddress = nil
            httpsFallback.committed(url)
            if loadOverride?(url) == true { return }
            onTypedCommit?()
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
