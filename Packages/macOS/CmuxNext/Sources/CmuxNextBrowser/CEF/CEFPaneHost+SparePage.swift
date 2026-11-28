import Foundation

/// How a tab joins this host's live Chromium window (`addToWindow`): it takes the spare page made
/// ahead (`CEFSpareWindow`), else Chromium makes its browser now (`tab_add`). Chromium's UI thread is
/// cmux's main thread, and `tab_add` held it about 12 ms per new tab (p50, `cef.tab_add`; fleet job
/// b1bf9573), 99 % of it Chromium's own, before the page's first frame: as Chrome on Android's
/// WarmupManager keeps a spare WebContents outside the tab model, the page is made at an idle moment.
extension CEFPaneHost {
    /// Chromium makes `tab`'s browser in this window now; its OnAfterCreated runs before it returns
    /// (`tabBeingAdded`). The new browser, or 0.
    func tabAdd(_ tab: CEFTab, anchor: Int32, activates: Bool) -> Int32 {
        guard let shim = runtime.shim else { return 0 }
        runtime.tabBeingAdded = tab
        defer { runtime.tabBeingAdded = nil }
        let add = { shim.tabAdd(anchor, tab.takeInitialURLString(), -1, activates ? 1 : 0) }
        #if DEBUG || CMUX_BENCH_HOOKS
        return runtime.benchMarks.span("cef.tab_add", add)
        #else
        return add()
        #endif
    }

    /// `tab` takes the spare page when one is ready and the tab may (`CEFSpareWindow.takePage`):
    /// the page moves into this window unless it is in it already (a pane that took the spare
    /// window), becomes Chromium's active tab when `activates` (as `tab_add` with activate does), is
    /// registered as `tab`'s browser, and loads the tab's address as its first navigation (the page
    /// was made with an empty URL, so it has no history entry before it). Nil: no spare page, or it
    /// could not move (it closes; the caller makes the tab's browser with `tab_add`).
    func joinSparePage(_ tab: CEFTab, anchor: Int32, activates: Bool) -> Int32? {
        guard let shim = runtime.shim, let page = runtime.spareWindow.takePage(for: tab, in: self) else { return nil }
        if page.host !== self {
            let move = { shim.tabMoveToWindow(page.browser, anchor, -1) }
            #if DEBUG || CMUX_BENCH_HOOKS
            let moved = runtime.benchMarks.span("cef.tab_move", move)
            #else
            let moved = move()
            #endif
            guard moved == 1 else {
                runtime.logger.error("CEF spare page \(page.browser) could not move into its pane's window; closing it")
                shim.close(page.browser)
                return nil
            }
        }
        // An agent-driven tab's address loads in `attach`, after its guard is set (`takeInitialURLString`).
        let url = tab.takeInitialURLString()
        if activates {
            // Chromium's echo of this activation is this host's own (`isForeignActivation`).
            lastActivated = page.browser
            _ = shim.tabActivate(page.browser)
        }
        runtime.register(tab, browser: page.browser)
        runtime.spareWindow.pageJoined(runtime: runtime)
        if !url.isEmpty { shim.loadURL(page.browser, url) }
        return page.browser
    }
}
