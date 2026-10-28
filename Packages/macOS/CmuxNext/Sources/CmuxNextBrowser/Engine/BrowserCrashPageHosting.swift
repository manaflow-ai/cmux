/// Tabs whose page process can end in a turn that also takes the page's pixels away: the Chromium
/// Host's end clears every hosted page's context in its exit turn. The tab asks its presenter to
/// show the crash page in that turn, not at the chrome's next render, so no frame shows the page
/// area empty. Chrome installs its sad tab in the exit callback itself
/// (`SadTabHelper::PrimaryMainFrameRenderProcessGone`, chrome/browser/ui/sad_tab_helper.cc).
protocol BrowserCrashPageHosting: AnyObject {
    /// The view that shows this tab's crash page: the chrome that binds the tab. The tab holds it weakly.
    var crashPagePresenter: (any BrowserCrashPagePresenter)? { get set }
}

/// The view that shows a tab's crash page (`BrowserChromeView`).
protocol BrowserCrashPagePresenter: AnyObject {
    /// Shows `tab`'s crash page now, from its state (``BrowserTabState/processExit``).
    func showCrashPage(of tab: any BrowserTab)
}
