/// What hides the tab's web view from WebKit (``WebKitPageVisibility``); the container applies it.
extension WebKitTab {
    /// WebKit draws in-view; with ``WebKitEngine/hidesHiddenTabs`` a hidden page's web view is hidden to WebKit,
    /// shown again in this call. A render-rate re-show of a page this hides ends: WebKit reads the rate when the
    /// page is next shown.
    public func setContentVisible(_ visible: Bool) {
        container.visibility.contentHidden = !visible
        if container.visibility.hidesContent { rateReshow?.cancel() }
    }

    /// An agent drives this tab in its off-screen render window (`AgentRenderWindows`) while `kept`: the page stays
    /// visible to WebKit there although the content lifecycle hid it.
    public func setKeptRendering(_ kept: Bool) { container.visibility.keptRendering = kept }

    /// Hides the web view for a render-rate re-show's hidden step (`WebKitRenderRate.reshow`) through the
    /// container, so a page hidden meanwhile stays hidden when the step ends.
    func setReshowing(_ reshowing: Bool) { container.visibility.reshowing = reshowing }
}
