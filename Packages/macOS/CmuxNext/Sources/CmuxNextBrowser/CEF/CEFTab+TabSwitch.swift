public import CmuxNextSignposts

/// The browser's side of the `switch.tab` interval (``TabSwitchSignpost``): what a switch to a page finds, and the
/// request a live Chromium page's show ends. Chrome stores that request on the destination WebContents
/// (`WebContentsImpl::SetTabSwitchStartTime`, content/browser/renderer_host/visible_time_request_trigger.h) and
/// takes it when the content becomes visible; here the destination ``CEFTab`` holds it until its page window shows
/// it (`CEFLayerHosting.pageShown`).
extension TabSwitchSignpost {
    /// What a switch to `tab` finds: a Chromium page whose browser exists (`page`), a page still to make
    /// (`cold`: a Chromium tab with no browser yet, a deferred or hibernated tab), or a live WebKit page (`warm`).
    public func kind(of tab: any BrowserTab) -> Kind {
        if let page = tab as? CEFTab { return page.browserID != nil ? .page : .cold }
        return tab is DeferredBrowserTab || tab is HibernatedBrowserTab ? .cold : .warm
    }

    /// The switch of `owner` shows `tab`: a Chromium page takes the request its page window's show ends, so the
    /// switch ends at that show's commit instead of the pane's. Other pages end at the pane's content commit.
    public func shows(_ tab: any BrowserTab, for owner: AnyObject) {
        guard let page = tab as? CEFTab, let show = pageShow(owner) else { return }
        page.tabSwitchShow = show
    }
}

extension CEFTab {
    /// Takes the `switch.tab` request waiting for this tab's show: one show ends one switch.
    func takeTabSwitchShow() -> TabSwitchSignpost.PageShow? {
        defer { tabSwitchShow = nil }
        return tabSwitchShow
    }
}
