public import CmuxNextSignposts

/// The browser's side of the `switch.tab` interval (``TabSwitchSignpost``): what a switch to a page finds, and the
/// request a live Chromium page's show marks. Chrome keys that request to the destination WebContents
/// (`WebContentsImpl::SetTabSwitchStartTime`, content/browser/renderer_host/visible_time_request_trigger.h); here the
/// destination ``CEFTab`` holds it until its page window shows it (`CEFLayerHosting.pageShown`).
extension TabSwitchSignpost {
    /// What a switch to `tab` finds: a Chromium page whose browser exists (`page`), a page still to make
    /// (`cold`: a Chromium tab with no browser yet, a deferred or hibernated tab), or a live WebKit page (`warm`).
    public func kind(of tab: any BrowserTab) -> Kind {
        if let page = tab as? CEFTab { return page.browserID != nil ? .page : .cold }
        return tab is DeferredBrowserTab || tab is HibernatedBrowserTab ? .cold : .warm
    }

    /// The switch of `owner` to `key` shows `tab`: a live Chromium page takes the request its page window's show
    /// marks. A page with no browser yet takes none: its switch ends at the pane's commit of its toolbar and themed
    /// page area, whether or not Chromium can make the browser.
    public func shows(_ tab: any BrowserTab, for owner: AnyObject, key: String) {
        guard let page = tab as? CEFTab, page.browserID != nil, let show = pageShow(owner, key: key) else { return }
        page.tabSwitchShow = show
    }
}

extension CEFTab {
    /// Takes the `switch.tab` request waiting for this tab's show: one show marks one switch.
    func takeTabSwitchShow() -> TabSwitchSignpost.PageShow? {
        defer { tabSwitchShow = nil }
        return tabSwitchShow
    }
}
