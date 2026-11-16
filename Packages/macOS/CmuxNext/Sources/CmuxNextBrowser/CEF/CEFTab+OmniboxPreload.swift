public import Foundation

/// Chrome's omnibox preloading for this tab (fork API 33, `cmux_omnibox_preload_*`): the profile's
/// AutocompleteActionPredictor scores the default match, then Chromium prerenders it in this tab
/// (confidence >= 0.5, PrerenderManager's direct-URL-input prerender, activated by Enter's load) or
/// preconnects to it (>= 0.3), under Chromium's own limits ("Preload pages", Battery Saver, Data Saver,
/// memory, one prerender per tab). Agent-driven tabs, sign-in tabs and tabs of a remote machine's store
/// never preload: the fork keeps a prerender's navigations from the shim's OnBeforeBrowse (it only refuses
/// non-http(s) URLs), so their per-tab guards would not see them.
extension CEFTab: BrowserOmniboxPreloading {
    @discardableResult
    public func omniboxPreload(text: String, matches: [OmniboxPreloadMatch]) -> OmniboxPreloadAction {
        guard let browserID, let shim = runtime.shim, preloads, !matches.isEmpty else { return .unavailable }
        let urls = matches.map { strdup($0.url.absoluteString) }
        defer { urls.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = urls.map { $0.map { UnsafePointer<CChar>($0) } }
        let types = matches.map(\.kind.rawValue)
        let raw = pointers.withUnsafeBufferPointer { urlBuffer in
            types.withUnsafeBufferPointer { typeBuffer in
                shim.omniboxPreloadTextChanged(browserID, text, urlBuffer.baseAddress, typeBuffer.baseAddress,
                                               Int32(matches.count), nil)
            }
        }
        return OmniboxPreloadAction(rawValue: raw) ?? .unavailable
    }

    /// Not gated on `preloads`: a tab an agent took over or a guard set mid-edit still ends its
    /// prerender (the fork drops the edit's matches; it learns nothing it was not given).
    public func omniboxPreloadEnded(opened: URL?, learn: Bool) {
        guard let browserID, let shim = runtime.shim,
              runtime.forkAPIVersion >= CEFTab.omniboxPreloadForkAPI else { return }
        _ = shim.omniboxPreloadOpened(browserID, opened?.absoluteString, learn ? 1 : 0)
    }

    private var preloads: Bool {
        runtime.forkAPIVersion >= CEFTab.omniboxPreloadForkAPI && !isAgentDriven && navigationGuard == .none
            && !runtime.signInCallbacks.isSignInTab(self)
    }

    /// The first fork API with omnibox preloading (manaflow-ai/cef CMUX-API.md).
    static let omniboxPreloadForkAPI: Int32 = 33
}
