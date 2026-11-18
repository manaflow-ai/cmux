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
        guard let browserID, let shim = runtime.shim, preloads, let first = matches.first,
              Self.preloads(under: navigationGuard, opening: first.url) else { return .unavailable }
        if omniboxRegistrations.isEmpty, runtime.omniboxPendingLearns[profileID]?.learns.isEmpty == false {
            // A new edit: first the edits the predictor could not learn while its database loaded. The
            // replay only teaches: prerendering is off meanwhile (the fork gives a preconnect at most for
            // an old text), and a URL this tab's guard refuses is dropped, never shown to the predictor.
            let guardRule = navigationGuard
            shim.setOmniboxPrerender(0)
            runtime.omniboxPendingLearns[profileID]?.replay(
                allowed: { Self.preloads(under: guardRule, opening: $0.opened) },
                register: { _ = Self.textChanged(shim, browserID, $0.text, $0.matches) },
                open: { shim.omniboxPreloadOpened(browserID, $0.opened.absoluteString, 1) })
            shim.setOmniboxPrerender(1)
        }
        omniboxRegistrations.append(.init(text: text, matches: matches))
        let raw = Self.textChanged(shim, browserID, text, matches)
        return OmniboxPreloadAction(rawValue: raw) ?? .unavailable
    }

    /// Not gated on `preloads`: a tab an agent took over or a guard set mid-edit still ends its
    /// prerender (the fork drops the edit's matches; it learns nothing it was not given). An edit the
    /// predictor could not learn yet (the fork answers 0 while its database loads) waits in
    /// `OmniboxPendingLearns` for the profile's next edit.
    public func omniboxPreloadEnded(opened: URL?, learn: Bool) {
        let registrations = omniboxRegistrations
        omniboxRegistrations = []
        guard let browserID, let shim = runtime.shim,
              runtime.forkAPIVersion >= CEFTab.omniboxPreloadForkAPI else { return }
        // An incognito store's edits are never kept (in memory past its window), nor a derived store's.
        guard learn, let opened, !registrations.isEmpty, !host.key.offTheRecord, host.key.machineKey == nil else {
            _ = shim.omniboxPreloadOpened(browserID, opened?.absoluteString, learn ? 1 : 0)
            return
        }
        runtime.omniboxPendingLearns[profileID, default: OmniboxPendingLearns()].ended(
            .init(registrations: registrations, opened: opened)) { shim.omniboxPreloadOpened(browserID, $0.opened.absoluteString, 1) }
    }

    /// `cmux_omnibox_preload_text_changed` for `text` and `matches` (the default first).
    private static func textChanged(_ shim: CEFShimLibrary, _ browserID: Int32, _ text: String,
                                    _ matches: [OmniboxPreloadMatch]) -> Int32 {
        let urls = matches.map { strdup($0.url.absoluteString) }
        defer { urls.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = urls.map { $0.map { UnsafePointer<CChar>($0) } }
        let types = matches.map(\.kind.rawValue)
        return pointers.withUnsafeBufferPointer { urlBuffer in
            types.withUnsafeBufferPointer { typeBuffer in
                shim.omniboxPreloadTextChanged(browserID, text, urlBuffer.baseAddress, typeBuffer.baseAddress,
                                               Int32(matches.count), nil)
            }
        }
    }

    private var preloads: Bool {
        runtime.forkAPIVersion >= CEFTab.omniboxPreloadForkAPI && !isAgentDriven
            && !runtime.signInCallbacks.isSignInTab(self)
    }

    /// Whether a tab whose store has `navigationGuard` may preload `url` (its default match). The
    /// fork keeps a prerender's navigations from the shim's OnBeforeBrowse, so the guard never sees
    /// them: a tab of this Mac (`exceptCloudDesktop`, every local tab: RemoteLocalhostStorePlan)
    /// preloads anything but an Open Desktop page, which its guard reroutes to that machine's store;
    /// a remote machine's stores never preload.
    static func preloads(under navigationGuard: BrowserNavigationGuard, opening url: URL) -> Bool {
        switch navigationGuard {
        case .none: true
        case .exceptCloudDesktop: !BrowserNavigationGuard.isCloudDesktop(url)
        case .loopbackOnly, .noLoopback: false
        }
    }

    /// The first fork API with omnibox preloading (manaflow-ai/cef CMUX-API.md).
    static let omniboxPreloadForkAPI: Int32 = 33
}
