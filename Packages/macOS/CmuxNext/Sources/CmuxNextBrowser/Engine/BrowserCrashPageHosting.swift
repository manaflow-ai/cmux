/// Tabs whose page process can end in a turn that also takes the page's pixels away: the Chromium
/// Host's end clears every hosted page's context in its exit turn. The tab asks its presenter to
/// show the crash page in that turn, not at the chrome's next render, so no frame shows the page
/// area empty. Chrome installs its sad tab in the exit callback itself
/// (`SadTabHelper::PrimaryMainFrameRenderProcessGone`, chrome/browser/ui/sad_tab_helper.cc).
protocol BrowserCrashPageHosting: AnyObject {
    /// The view that shows this tab's crash page: the chrome that binds the tab. The tab holds it weakly.
    var crashPagePresenter: (any BrowserCrashPagePresenter)? { get set }
    /// The tab's cookies and site data live only in its engine's memory (an incognito window's store): an
    /// end of the process that held them takes them, and its crash page says so.
    var keepsSiteDataInMemoryOnly: Bool { get }
    /// The crash page's Reload All Tabs after the Chromium Host ended, when no action registry routes it
    /// (``PageStatusViews/reloadAllRouter``): every tab the end left reloads, the shown ones now.
    func reloadAllTabsTheHostEndLeft()
}

/// The view that shows a tab's crash page (`BrowserChromeView`).
protocol BrowserCrashPagePresenter: AnyObject {
    /// Shows `tab`'s crash page now, from its state (``BrowserTabState/processExit``).
    func showCrashPage(of tab: any BrowserTab)
}
