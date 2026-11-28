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

    /// The first page to join the cmux pages' window takes its placeholder's browser as its own
    /// (`adoptablePlaceholder`): no `tab_add`, so no new Chromium browser is made on the page's open. That
    /// call held the main thread 2.1 s and 4.6 s in Leo's NIGHTLY at 2-4 % CPU, blocked on page-ins in
    /// Chromium's new-browser setup (cmuxterm-hq#27488), as the spare page's did (`CEFSpareWindow.stallBudget`).
    /// The browser was made with no URL when the window was (no history entry before the page's own,
    /// as a spare page), and is the window's only and active tab; it thaws, is registered as `tab`'s, and
    /// loads the tab's address as its first navigation. The placeholder tab closes without closing it.
    /// Nil: no such placeholder, or `tab` restores history (the caller makes its browser as before).
    func adoptPlaceholder(_ tab: CEFTab) -> Int32? {
        guard adoptablePlaceholder, !isSpare, !holdsOwnTab, let blank = placeholder, blank !== tab, !blank.isClosed,
              let browser = blank.browserID, tab.pendingRestore == nil, tab.browserID == nil,
              let shim = runtime.shim, shim.tabWindowID(browser) != 0 else { return nil }
        adoptablePlaceholder = false
        placeholder = nil
        // An agent-driven tab's address loads in `attach`, after its guard is set (`takeInitialURLString`).
        let url = tab.takeInitialURLString()
        blank.handBrowserOver()
        // Activated as `joinSparePage` does: a never-shown placeholder may still count hidden in Chromium.
        _ = shim.tabActivate(browser)
        lastActivated = browser
        runtime.register(tab, browser: browser)
        // No browser left, so this only leaves the host (`CEFTab.close`).
        blank.close()
        // Frozen through DevTools as soon as it existed (`CEFTab.freezeNeverShownPage`). The address loads only
        // after Chromium answered the thaw: a load sent beside it ran in the still-frozen page and the New Tab
        // page stayed blank on the second Command-T (CMUX-1004). One DevTools round trip, still no `tab_add`.
        let thaw = runtime.startDevTools(browser, method: "Page.setWebLifecycleState", params: ["state": "active"]) { true }
        // task-owner: the page's own open; ends with the thaw's answer or its timeout.
        Task { @MainActor [weak self, weak tab] in
            _ = try? await thaw()
            guard let self, let tab, tab.browserID == browser, !tab.isClosed else { return }
            if !url.isEmpty { self.runtime.shim?.loadURL(browser, url) }
            self.reloadIfNeverCommitted(tab, browser: browser, url: url)
        }
        // Never inside Chromium's creation stack (this may run inside OnAfterCreated, `windowCreated`).
        endOfTurn { [weak self] in self?.adoptParkedTabs() }
        return browser
    }

    /// The adopted placeholder never committed its first navigation (CMUX-1004): the page loads its address once
    /// more after `adoptedCommitBudget`, so the worst case is a slow open, never an empty tab.
    func reloadIfNeverCommitted(_ tab: CEFTab, browser: Int32, url: String) {
        guard !url.isEmpty else { return }
        // task-owner: one bounded check of the page's own open.
        Task { @MainActor [weak self, weak tab] in
            try? await Task.sleep(for: Self.adoptedCommitBudget)
            guard let self, let tab, tab.browserID == browser, !tab.isClosed, tab.committedURL == nil else { return }
            CEFPageFreeze.devTools.thaw(browser, runtime: self.runtime)
            self.runtime.shim?.loadURL(browser, url)
        }
    }

    static let adoptedCommitBudget: Duration = .milliseconds(1500)

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
