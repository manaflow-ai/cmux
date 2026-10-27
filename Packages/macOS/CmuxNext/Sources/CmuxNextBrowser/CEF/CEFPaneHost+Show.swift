import Foundation
import os

extension CEFPaneHost {
    /// Makes the shown tab's browser Chromium's active tab and puts the page window over this
    /// host's view. Also for a tab whose browser joined a live window after the frame
    /// (`createDeferred`) or once its window came up (`windowCreated`): `tab_add` alone left
    /// that pane on its empty themed area, or the page at the place and clip the fork last read.
    /// `activate`: false when Chromium already made it the active tab (`tab_add` with activate,
    /// the window's first tab), so one activation, and one echo of it, reaches Chromium.
    ///
    /// A hosted page (``CEFLayerHosting/showsInSwitchTransaction``) shows in the switch's own frame
    /// with no fork call in its turn: the activation and the input window's place run after the
    /// commit, as Chrome's tab strip commits the switch and the page's frame follows. The echo of
    /// the activation is still this host's own (`lastActivated`, set now).
    func showBrowser(of tab: CEFTab, activate: Bool = true) {
        guard let browser = tab.browserID else { return }
        let hosting = hostView.layerHosting
        if activate { lastActivated = browser }
        if hosting.showsInSwitchTransaction {
            hosting.pageShown(browser: browser, tabSwitch: tab.takeTabSwitchShow())
            var activation: (@MainActor () -> Void)?
            if activate { activation = { [weak self, weak tab] in self?.activateShown(tab, browser: browser) } }
            hosting.showAfterCommit(activate: activation) { [weak self] in self?.hostView.postGeometryChange() }
        } else {
            if activate { activateNow(browser) }
            hosting.pageShown(browser: browser, tabSwitch: tab.takeTabSwitchShow())
            hostView.postGeometryChange()
        }
        showPageCursor(of: browser)
        showPageAccessibility(of: browser)
        suggestionsFollowShownBrowser(browser)
        // Another page's pointer lock, keyboard lock and fullscreen end (task 229).
        hostedPageView?.exclusiveAccess.showing(browser)
        // Host mode: a display the page view read while no tab was shown (it entered another
        // window before this tab was shown in it) is placed now (task 221).
        hostedPageView?.placeIfNeeded()
        // A window-wide side panel stays open across tabs: no event.
        tab.sidePanel.scheduleRefresh()
    }

    /// The held activation of a hosted show: only while `tab` is still the shown tab of that browser
    /// (a later show of the turn held its own; a closed tab needs none).
    private func activateShown(_ tab: CEFTab?, browser: Int32) {
        guard let tab, visibleTab === tab, tab.browserID == browser, !tab.isClosed else { return }
        activateNow(browser)
    }

    private func activateNow(_ browser: Int32) {
        tabSwitchMark("activate")
        _ = runtime.shim?.tabActivate(browser)
        tabSwitchMark("activated")
    }

    /// `windowCreated`'s show of the tab shown now, already Chromium's active tab.
    func showCreatedWindow() {
        guard isLive, let visible = visibleTab, !visible.awaitsWindowMove, visible.browserID != nil else { return }
        showBrowser(of: visible, activate: false)
    }

    /// The pane's layout spring landed (`CEFTabContentView.paneMotionDidSettle`): the fork re-reads
    /// the shown page's place and clip at the landed frame. A spring that holds the page at its rest
    /// size moves and clips only its ancestors, which the fork hears only while it tracks the view's
    /// current superview chain; the landing must never leave the page at a mid-motion place or clip.
    func paneMotionSettled(_ tab: CEFTab) {
        guard visibleTab === tab, tab.browserID != nil, !tab.awaitsWindowMove else { return }
        hostView.postGeometryChange()
    }
}

/// Tab switch timeline marks (cx-asb1), `activate` and `activated`: wall-clock
/// ms, the clock of every other writer to category "tab-switch" (the control
/// router's `request` and `run`, the pane's `show` and `shown`, the occlusion
/// marks), so one log stream reads as one timeline. Debug level: nothing is
/// written unless a `log stream --level debug` reads category "tab-switch".
private let tabSwitchLog = Logger(subsystem: "com.cmuxterm.app.next", category: "tab-switch")
private func tabSwitchMark(_ name: String) {
    // wall-clock: same timeline as the other tab-switch marks; the category moves to TraceClock in one change.
    tabSwitchLog.debug("tab-switch \(name, privacy: .public) \(Date().timeIntervalSince1970 * 1_000, format: .fixed(precision: 3), privacy: .public)")
}
