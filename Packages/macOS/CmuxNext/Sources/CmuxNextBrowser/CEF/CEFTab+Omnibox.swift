import Foundation

/// chrome.omnibox keyword sessions of this tab's profile (fork API 12).
extension CEFTab: BrowserOmniboxKeywordProviding {
    /// Read on every omnibar step: cached per profile until extensions
    /// change (`CEFOmniboxKeywords.invalidate`).
    public func omniboxKeywords() -> [OmnibarKeyword] {
        guard let browserID, let shim = runtime.shim, runtime.forkAPIVersion >= 12 else { return [] }
        return runtime.omniboxKeywords.keywords(profile: profileID, browser: browserID, shim: shim)
    }

    public func omniboxKeywordStarted(_ extensionID: String) {
        guard let browserID, let shim = runtime.shim else { return }
        runtime.omniboxKeywords.started(browser: browserID, extensionID: extensionID, shim: shim)
    }

    public func omniboxKeywordSuggestions(_ extensionID: String, text: String) async -> [BrowserSuggestion] {
        guard let browserID, let shim = runtime.shim,
              let keyword = omniboxKeywords().first(where: { $0.extensionID == extensionID }) else { return [] }
        let json = await runtime.omniboxKeywords.suggestions(browser: browserID, extensionID: extensionID, text: text, shim: shim)
        return CEFOmniboxKeywords.rows(json: json ?? "[]", keyword: keyword, text: text)
    }

    public func omniboxKeywordEntered(_ extensionID: String, text: String, disposition: OmnibarDisposition) {
        guard let browserID, let shim = runtime.shim else { return }
        runtime.omniboxKeywords.entered(browser: browserID, extensionID: extensionID, text: text,
                                        disposition: disposition, shim: shim)
    }

    public func omniboxKeywordEnded(_ extensionID: String) {
        guard let browserID, let shim = runtime.shim else { return }
        runtime.omniboxKeywords.ended(browser: browserID, extensionID: extensionID, shim: shim)
    }
}
