import AppKit

/// Host mode's DevTools placement (task 024 of plans/cmux-next/chrome-parity/p01-process.md): the
/// DevTools of a page that runs in the Chromium Host is a hosted context, shown in a
/// ``ChromiumHostPageView`` at the bottom of the docked DevTools view (``CEFDevToolsController/views``),
/// docked in the pane or in the ``CEFDevToolsWindow`` panel. No view pointer crosses the wire: the
/// placement names the page view's token, and the host keeps a view of its own behind it
/// (host_dispatch.h, `PageViews`) while that placement or its DevTools lives.
///
/// In process, cmux places a DevTools inside `DEVTOOLS_WILL_OPEN`, which Chromium sends before it
/// makes the DevTools and reads the placement when the event returns. The host does not wait for
/// cmux, so the placement goes first and stands: cmux places once per inspected browser, before
/// the first command or page menu that may open DevTools, and the host keeps it across DevTools
/// closes until the browser closes. Chromium's own opens (the page menu's Inspect) land placed and
/// keep their target. Chrome decides the same way in its browser process, from state it already has
/// (chrome/browser/devtools/devtools_window.cc, `DevToolsWindow::Create` reads the dock side from
/// prefs; it never asks the window's process). The event only keeps room in the pane.
extension CEFDevToolsController {
    /// Whether `command` can make Chromium create DevTools (so a placement goes first).
    nonisolated static func mayCreateDevTools(_ command: BrowserDevToolsCommand) -> Bool {
        switch command {
        case .show, .console, .inspectElement, .panel: true
        case .toggle, .close, .dock: false
        }
    }

    /// Host mode: makes the host hold a placement for the tab's browser (once per browser).
    func placeHosted(in tab: CEFTab) {
        guard tab.host.isHostMode, let browser = tab.browserID, hostedPlacement != browser else { return }
        sendHostedPlacement(in: tab, browser: browser)
    }

    /// Host mode: sends the standing placement again for a new dock or size.
    func refreshHostedPlacement(in tab: CEFTab) {
        guard tab.host.isHostMode, let browser = tab.browserID, hostedPlacement == browser else { return }
        sendHostedPlacement(in: tab, browser: browser)
    }

    /// Chromium's page menu is about to show. Its rows that open DevTools (Inspect) run in the host
    /// after this, so in host mode the placement goes first. The host keeps the placement's view
    /// for the tab's life, so a tab gets it only once a menu or command may open DevTools.
    func pageMenuWillShow() {
        guard let tab else { return }
        placeHosted(in: tab)
    }

    /// Tells the host that every DevTools of `browser` goes in ``hostedPage``, sized for the current dock.
    private func sendHostedPlacement(in tab: CEFTab, browser: Int32) {
        guard let shim = tab.runtime.shim else { return }
        let page = hostedPage(for: tab)
        let size = layout.dock.isDocked
            ? layout.frames(in: tab.container.bounds, devToolsDocked: true).devTools.size
            : CEFDevToolsWindow.frame(near: tab.container.window).size
        shim.devToolsSetPlacement(browser, CEFParentView(token: page.wireToken), 0, 0,
                                  max(size.width, 1).clampedInt32, max(size.height, 1).clampedInt32)
        hostedPlacement = browser
    }

    /// Host mode: the view DevTools shows in, made once per tab with its own wire token.
    func hostedPage(for tab: CEFTab) -> ChromiumHostPageView {
        if let hostedPage { return hostedPage }
        // No input route to the host yet (tasks 041 and 042): the page view takes no input, as the
        // pane's. Its input method ops go to the host for the DevTools browser, as the pane's do.
        let page = ChromiumHostPageView(frame: .zero, inputTarget: .pageWindow)
        page.wireToken = tab.runtime.mintPageViewToken()
        // What the person sees of the DevTools page goes to the host, as the pane's page does
        // (``postPageVisibility(browser:)``): its page window is detached too.
        page.onPageVisibility = { [weak self] _ in self?.postPageVisibility() }
        // DevTools' page window takes the view's display, as the pane's page does (task 221).
        page.onScreenInfo = { [weak self, weak page, weak runtime = tab.runtime] _ in
            guard let self, let page, let runtime, let browser = devToolsBrowserID else { return false }
            return runtime.placeHostedPage(page, browser: browser)
        }
        #if DEBUG || CMUX_BENCH_HOOKS
        page.textInputSink = { [weak self] op in self?.sendTextInput(op) }
        #endif
        hostedPage = page
        return page
    }

    /// Host mode: tells the host what the person sees of ``hostedPage``
    /// (``ChromiumHostPageView/pageVisibility``) for DevTools browser `browser` (by default the open
    /// one), as ``CEFPaneHost/postPageVisibility(browser:)`` does for the pane's page. Nothing goes
    /// while no DevTools is open.
    func postPageVisibility(browser: Int32? = nil) {
        guard let page = hostedPage, let browser = browser ?? devToolsBrowserID else { return }
        _ = tab?.runtime.shim?.browserSetPageVisibility(browser, page.pageVisibility.rawValue)
    }

    /// Host mode: ``hostedPage`` while it shows DevTools browser `browser`, the view its `<select>`
    /// popups show over: in the DevTools window, or docked while the pane shows the tab (as a page's
    /// popups need its tab shown, ``CEFRuntime/popupMenuView(of:)``). Nil otherwise.
    func hostedPopupMenuView(of browser: Int32) -> NSView? {
        guard devToolsBrowserID == browser, let tab, tab.devTools.isOpen, let page = hostedPage, page.window != nil,
              !tab.devTools.dock.isDocked || tab.host.visibleTab === tab else { return nil }
        return page
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Host mode: sends the DevTools page view's input method op to the host's IME exports for the
    /// DevTools browser (``CEFPaneHost/sendTextInput(_:)``); nothing goes while no DevTools is open
    /// or when the host's shim lacks an IME op.
    func sendTextInput(_ op: ChromiumHostTextInputOp) {
        guard let browser = devToolsBrowserID, let ime = tab?.runtime.shim?.textInput, ime.isComplete else { return }
        ime.send(op, browser: browser)
    }
    #endif

    /// Host mode: puts ``hostedPage`` at the bottom of `host`, filling it, under the divider's
    /// and every other subview.
    func installHostedPage(for tab: CEFTab, in host: NSView) {
        let page = hostedPage(for: tab)
        page.frame = host.bounds
        page.autoresizingMask = [.width, .height]
        host.addSubview(page, positioned: .below, relativeTo: nil)
    }

    /// Host mode: an opening command went to the host. It is a new open in flight unless DevTools is
    /// open or on its way, where it only retargets that open (``hostedRequests``).
    func hostedOpenSent(_ command: BrowserDevToolsCommand, browser: Int32) {
        if isOpenOrRequested {
            hostedRequests.retarget(command, browser: browser)
        } else {
            hostedRequests.sent(.open(command), browser: browser)
        }
    }

    /// Host mode: `DEVTOOLS_WILL_OPEN` came after Chromium made the DevTools. With a placement standing
    /// it is in ``hostedPage``: the pane keeps room for it. Without one it went to a window of the
    /// host's own; ``opened(browser:docked:)`` closes it. One cmux closed again before it opened gets
    /// no room: the close is on the wire.
    func hostedWillOpen(in tab: CEFTab) {
        guard let browser = tab.browserID, hostedPlacement == browser,
              !hostedRequests.closesAfterOpening(browser: browser) else {
            opening = false
            return
        }
        let views = views ?? makeViews(in: tab)
        tab.container.layoutContent()
        if views.host.bounds.isEmpty { views.host.frame = tab.container.bounds }
    }

    /// Host mode: a DevTools the shim made with no placement view, in a top-level window of the host.
    /// A fault path: with the placement standing, only an open Chromium started before cmux placed
    /// gets here. It closes, and `reopen` (the command cmux asked for, or a show) runs once after,
    /// placed. A reopen that is still unplaced was made after the placement and stays closed.
    func closeUnplaced(in tab: CEFTab, reopen: BrowserDevToolsCommand?) {
        tab.runtime.logger.error("Chromium Host opened DevTools with no placement; closing it")
        if let reopen {
            afterClose = reopen
            reopeningUnplaced = true
        }
        if let browser = tab.browserID {
            _ = tab.runtime.shim?.devToolsCommand(browser, CEFShimLibrary.DevToolsCommand.close, 0, 0)
        }
    }

    /// Host mode: shows DevTools browser `devTools` in ``hostedPage``. The host turns on the fork's
    /// layer hosting (API 26) of the DevTools page window it keeps behind the page view's token, and
    /// its REPLY carries that window's Core Animation context id, as for a pane's page
    /// (``CEFPaneHost/showHostedContext(of:)``). A reply after that DevTools closed shows nothing.
    func showHostedContext(of devTools: Int32) {
        guard let tab, let page = hostedPage else { return }
        let runtime = tab.runtime
        let forkAPI = runtime.forkAPIVersion
        guard forkAPI >= CEFLayerHosting.forkAPI else {
            return runtime.logger.error("Chromium Host fork API \(forkAPI) cannot layer-host DevTools")
        }
        // Before the hosting op: the host applies it when it detaches the DevTools page window.
        postPageVisibility(browser: devTools)
        let sent = runtime.sendAsync { $0.browserSetLayerHosting(devTools, 1) }
        runtime.placeHostedPage(page, browser: devTools)
        runtime.whenAnswered(sent, label: "DevTools context") { [weak self, weak page, weak runtime] id in
            guard let self, let page, hostedPage === page, devToolsBrowserID == devTools else { return }
            if let id, id != 0, page.show(contextID: id) { return }
            runtime?.logger.error("Chromium Host gave no context for DevTools browser \(devTools)")
        }
    }
}
