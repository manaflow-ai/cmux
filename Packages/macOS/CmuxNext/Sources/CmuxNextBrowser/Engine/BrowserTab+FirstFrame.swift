extension Array where Element == any BrowserTab {
    /// What a frame holds for these shown pages (the hover preload bench's first-frame probe,
    /// `debug.workspace_switch`): `pages` shown, `pages_placeholder` a stand-in with no live page (a
    /// hibernated snapshot or blank, or a deferred page), `pages_loading` a live page whose load has not
    /// ended (blank or partial). The rest show their loaded page in that frame.
    @MainActor package var firstFrameColumns: [String: Double] {
        let placeholders = filter { $0 is HibernatedBrowserTab || $0 is DeferredBrowserTab }.count
        let loading = filter { !($0 is HibernatedBrowserTab || $0 is DeferredBrowserTab) && $0.state.isLoading }.count
        return ["pages": Double(count), "pages_placeholder": Double(placeholders), "pages_loading": Double(loading)]
    }
}
