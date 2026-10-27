/// Host mode after a crash of cmux (task p01-process-150, ``CEFAdoptedPages``): a restored tab takes back the page the
/// adopted Chromium Host kept for it instead of creating one. The pane's first such tab takes its page's Chromium
/// window as the pane's window, as if its `create_window` had just answered: the pane's page view takes the token
/// the window's parent view has in the host, and shows the page's Core Animation context at once (the host answers
/// the hosting op again with it); later tabs of the pane take their pages from that window.
extension CEFPaneHost {
    /// Binds `tab`, which has no browser and whose pane has no window, to its adopted page. False when there is none,
    /// or it cannot show here (then it closed, and the caller creates the tab's page).
    func bindAdoptedPage(_ tab: CEFTab) -> Bool {
        guard isHostMode, case .none = window,
              let page = runtime.claimAdoptedPage(for: tab, pane: self, liveWindow: nil) else { return false }
        tab.takeAdoptedPage()
        if page.view != 0 { hostedPage().wireToken = page.view }
        if page.context != 0 { hostedPage().show(contextID: page.context) }
        let request = runtime.makeRequestToken()
        tab.isCreationPending = true
        windowTab = tab
        window = .creating(request: request)
        windowCreated(browser: page.browser, request: request, knownWindow: page.window)
        return true
    }

    /// The browser of `tab`'s adopted page in this pane's live window `live`, ready for the tab to register; nil when
    /// there is none (a page of its key in another window closed).
    func adoptedPage(for tab: CEFTab, inWindow live: Int32) -> Int32? {
        guard isHostMode, let page = runtime.claimAdoptedPage(for: tab, pane: self, liveWindow: live) else { return nil }
        tab.takeAdoptedPage()
        return page.browser
    }
}

extension CEFTab {
    /// The tab shows a page an adopted host kept (``CEFPaneHost/bindAdoptedPage(_:)``): the page is already at its
    /// last committed entry with its whole history, so nothing loads or restores into it at the attach.
    func takeAdoptedPage() {
        loadAfterAttach = nil
        pendingRestore = nil
    }
}
