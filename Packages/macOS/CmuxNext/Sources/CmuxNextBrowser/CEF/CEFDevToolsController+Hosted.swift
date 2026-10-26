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
/// cmux, so the placement goes first: cmux places before each command that may open DevTools, and
/// the event only keeps room in the pane. Chrome decides the same way in its browser process,
/// from state it already has (chrome/browser/devtools/devtools_window.cc,
/// `DevToolsWindow::Create` reads the dock side from prefs; it never asks the window's process).
extension CEFDevToolsController {
    /// Whether `command` can make Chromium create DevTools (so a placement goes first).
    nonisolated static func mayCreateDevTools(_ command: BrowserDevToolsCommand) -> Bool {
        switch command {
        case .show, .console, .inspectElement, .panel: true
        case .toggle, .close, .dock: false
        }
    }

    /// Host mode: tells the host that the next DevTools of `browser` goes in ``hostedPage``, sized
    /// for the current dock. Once per open: the host drops the placement when that DevTools closes.
    func placeHosted(in tab: CEFTab, browser: Int32, shim: CEFShimLibrary) {
        guard hostedPlacement != browser else { return }
        let page = hostedPage(for: tab)
        let size = layout.dock.isDocked
            ? layout.frames(in: tab.container.bounds, devToolsDocked: true).devTools.size
            : CEFDevToolsWindow.frame(near: tab.container.window).size
        shim.devToolsSetPlacement(browser, UnsafeMutableRawPointer(bitPattern: UInt(page.wireToken)), 0, 0,
                                  max(size.width, 1).clampedInt32, max(size.height, 1).clampedInt32)
        hostedPlacement = browser
    }

    /// Host mode: the view DevTools shows in, made once per tab with its own wire token.
    func hostedPage(for tab: CEFTab) -> ChromiumHostPageView {
        if let hostedPage { return hostedPage }
        // No input route to the host yet (tasks 041 and 042): the page view takes no input, as the pane's.
        let page = ChromiumHostPageView(frame: .zero, inputTarget: .pageWindow)
        page.wireToken = tab.runtime.mintPageViewToken()
        hostedPage = page
        return page
    }

    /// Host mode: puts ``hostedPage`` at the bottom of `host`, filling it, under the divider's
    /// and every other subview.
    func installHostedPage(for tab: CEFTab, in host: NSView) {
        let page = hostedPage(for: tab)
        page.frame = host.bounds
        page.autoresizingMask = [.width, .height]
        host.addSubview(page, positioned: .below, relativeTo: nil)
    }

    /// Host mode: `DEVTOOLS_WILL_OPEN` came after Chromium made the DevTools. A placed one is in
    /// ``hostedPage``: the pane keeps room for it. One nothing placed (an open the host started)
    /// went to a window of the host's own; ``opened(browser:docked:)`` moves it.
    func hostedWillOpen(in tab: CEFTab) {
        guard let browser = tab.browserID, hostedPlacement == browser else {
            opening = false
            return
        }
        let views = views ?? makeViews(in: tab)
        tab.container.layoutContent()
        if views.host.bounds.isEmpty { views.host.frame = tab.container.bounds }
    }

    /// Host mode: a DevTools that opened in a window of the host's own, which never shows. One that
    /// nothing placed closes and opens again in ``hostedPage``; one the host was told to place and
    /// did not stays closed (opening it again would loop).
    func closeUnplaced(in tab: CEFTab, wasPlaced: Bool) {
        if wasPlaced {
            tab.runtime.logger.error("Chromium Host opened DevTools outside its placement; closing it")
        } else {
            afterClose = .show
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
        let sent = runtime.sendAsync { $0.browserSetLayerHosting(devTools, 1) }
        runtime.whenAnswered(sent, label: "DevTools context") { [weak self, weak page, weak runtime] id in
            guard let self, let page, hostedPage === page, devToolsBrowserID == devTools else { return }
            if let id, id != 0, page.show(contextID: id) { return }
            runtime?.logger.error("Chromium Host gave no context for DevTools browser \(devTools)")
        }
    }
}
