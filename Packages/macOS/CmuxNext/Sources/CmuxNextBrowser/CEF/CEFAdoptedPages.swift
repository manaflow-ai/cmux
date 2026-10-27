/// The pages a Chromium Host this cmux adopted kept from the crashed cmux (task p01-process-150 of
/// plans/cmux-next/chrome-parity/p01-process.md; the host's reply lists them, `ChromiumHostAdoptedPage`), by the key of
/// the tab each showed (its `BrowserTabID`, which the daemon keeps across the crash). A restored tab of that key takes
/// its page back instead of creating one, so the page is never reloaded (its `performance.timeOrigin` stays), as
/// Chrome's session restore reconnects a tab to a `WebContents` it still has rather than loading it again.
///
/// One pane shows one Chromium window: the first tab of a pane with no window takes its page's window for that pane,
/// and a later tab of the pane takes its page only from that window. A page another pane's window holds, or one in
/// another window than its pane's, is discarded (the tab creates its page anew). What no tab took by the end of the
/// claim window is discarded too (``takeUnclaimed()``), so no page runs on that nobody shows or can close.
nonisolated struct CEFAdoptedPages: Equatable, Sendable {
    /// What a tab's claim found.
    nonisolated enum Claim: Equatable, Sendable {
        /// The tab shows this page.
        case bind(ChromiumHostAdoptedPage)
        /// The tab's page cannot be shown where the tab is: it closes, and the tab creates its own.
        case discard(ChromiumHostAdoptedPage)
        /// No adopted page has the tab's key.
        case noPage
    }

    private var byKey: [String: ChromiumHostAdoptedPage] = [:]
    /// The pane that took each Chromium window, by window.
    private var paneOfWindow: [Int32: ObjectIdentifier] = [:]
    /// Pages tabs took and pages discarded so far (`debug.cef`).
    private(set) var bound = 0
    private(set) var discarded = 0

    init(_ pages: [ChromiumHostAdoptedPage] = []) {
        for page in pages { byKey[page.key] = page }
    }

    /// Pages no tab took yet.
    var waiting: Int { byKey.count }

    /// The page of `key` for a tab of `pane`, whose live Chromium window is `liveWindow` (nil: the pane has none
    /// yet). The page leaves the waiting pages either way.
    mutating func claim(key: String, pane: ObjectIdentifier, liveWindow: Int32?) -> Claim {
        guard let page = byKey.removeValue(forKey: key) else { return .noPage }
        let fits: Bool
        if let liveWindow {
            fits = page.window == liveWindow
        } else {
            fits = paneOfWindow[page.window].map { $0 == pane } ?? true
        }
        guard fits else {
            discarded += 1
            return .discard(page)
        }
        paneOfWindow[page.window] = pane
        bound += 1
        return .bind(page)
    }

    /// `browser` closed: a waiting page of it is gone.
    mutating func closed(browser: Int32) {
        guard let key = byKey.first(where: { $0.value.browser == browser })?.key else { return }
        byKey[key] = nil
    }

    /// The claim window ended: every page no tab took, to close.
    mutating func takeUnclaimed() -> [ChromiumHostAdoptedPage] {
        let unclaimed = byKey.values.sorted { $0.browser < $1.browser }
        discarded += unclaimed.count
        byKey = [:]
        return unclaimed
    }
}
