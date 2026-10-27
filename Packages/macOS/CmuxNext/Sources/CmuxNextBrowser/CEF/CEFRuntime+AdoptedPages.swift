import Foundation

/// Host mode: the pages a Chromium Host this cmux adopted kept from the crashed cmux (task p01-process-150 of
/// plans/cmux-next/chrome-parity/p01-process.md, ``CEFAdoptedPages``). Each tab tells the host its key when it gets a
/// page (``sendPageKey(of:browser:)``), so the next adoption's reply names the page by it; a restored tab of that key
/// takes the page back (`CEFPaneHost.bindAdoptedPage(_:)`); what no tab took within ``adoptedPageClaimWindow``
/// closes, as Chrome closes a restored window's tabs nobody took back (`SessionRestore`'s discard of unused
/// `WebContents`), so an adoption never leaves pages running that nothing shows.
extension CEFRuntime {
    /// How long after the start restored tabs may take back the adopted pages; the rest close then. The same 30 s the
    /// orphaned host waited for this cmux: a tab shown later (a background tab restored as a placeholder) loads its
    /// page from its history record, as without an adoption.
    static let adoptedPageClaimWindow: Duration = .seconds(30)

    /// The start attached a host (`CEFAttachedHost`): one adopted from a crashed cmux brings `pages` and the first page
    /// view token this cmux may mint, `viewTokenFloor` (0: any). This cmux's tokens start there, also those of page
    /// views made before the start, so no new pane names a page view the host keeps for an adopted window.
    func takeAdoptedPages(_ pages: [ChromiumHostAdoptedPage], viewTokenFloor: UInt64) {
        if viewTokenFloor > 0, lastPageViewToken < viewTokenFloor - 1 {
            lastPageViewToken = viewTokenFloor - 1
            for pane in hosts.values {
                guard let page = pane.hostedPageView, page.wireToken < viewTokenFloor else { continue }
                page.wireToken = mintPageViewToken()
            }
        }
        if let adoptedPagesDeadline { _ = waitDeadlines.cancel(adoptedPagesDeadline) }
        adoptedPagesDeadline = nil
        adoptedPages = CEFAdoptedPages(pages)
        guard adoptedPages.waiting > 0 else { return }
        logger.notice("chromium host adopted with \(self.adoptedPages.waiting) pages for restored tabs")
        adoptedPagesDeadline = waitDeadlines.schedule(owner: "CEFRuntime.adoptedPages", after: Self.adoptedPageClaimWindow) {
            [weak self] in self?.closeUnclaimedAdoptedPages()
        }
    }

    /// The page an adopted host kept for `tab`, shown in `pane` (whose live Chromium window is `liveWindow`), when it
    /// can show there; a page of the tab's key that cannot closes now, and the tab creates its own.
    func claimAdoptedPage(for tab: CEFTab, pane: CEFPaneHost, liveWindow: Int32?) -> ChromiumHostAdoptedPage? {
        guard adoptedPages.waiting > 0 else { return nil }
        switch adoptedPages.claim(key: tab.id.rawValue, pane: ObjectIdentifier(pane), liveWindow: liveWindow) {
        case .bind(let page):
            tab.host.lifecycleTrace.record(tab.id, "adopted page \(page.browser)")
            return page
        case .discard(let page):
            shim?.close(page.browser)
            return nil
        case .noPage:
            return nil
        }
    }

    /// The claim window ended: every adopted page no tab took closes.
    func closeUnclaimedAdoptedPages() {
        adoptedPagesDeadline = nil
        let unclaimed = adoptedPages.takeUnclaimed()
        guard !unclaimed.isEmpty else { return }
        logger.notice("closing \(unclaimed.count) adopted Chromium pages no restored tab took")
        for page in unclaimed { shim?.close(page.browser) }
    }

    /// The host ended (``hostEnded(_:)``): its pages went with it.
    func dropAdoptedPages() {
        if let adoptedPagesDeadline { _ = waitDeadlines.cancel(adoptedPagesDeadline) }
        adoptedPagesDeadline = nil
        adoptedPages = CEFAdoptedPages()
    }

    /// `tab` shows `browser`: the host learns the tab's key, which a later adoption names the page by. A host that
    /// keeps no pages after a crash of cmux takes no key (the remote shim sends nothing).
    func sendPageKey(of tab: CEFTab, browser: Int32) {
        hostStart?.remote?.setPageKey(tab.id.rawValue, browser: browser)
    }
}
