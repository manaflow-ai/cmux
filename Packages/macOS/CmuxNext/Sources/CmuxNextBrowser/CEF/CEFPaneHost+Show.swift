import Foundation
import os

extension CEFPaneHost {
    /// Makes the shown tab's browser Chromium's active tab and puts the page window over this
    /// host's view. Also for a tab whose browser joined a live window after the frame
    /// (`createDeferred`) or once its window came up (`windowCreated`): `tab_add` alone left
    /// that pane on its empty themed area, or the page at the place and clip the fork last read.
    /// `activate`: false when Chromium already made it the active tab (`tab_add` with activate,
    /// the window's first tab), so one activation, and one echo of it, reaches Chromium.
    func showBrowser(of tab: CEFTab, activate: Bool = true) {
        guard let browser = tab.browserID else { return }
        if activate {
            lastActivated = browser
            tabSwitchMark("activate")
            _ = runtime.shim?.tabActivate(browser)
            tabSwitchMark("activated")
        }
        hostView.layerHosting.pageShown(browser: browser)
        hostView.postGeometryChange()
        // A window-wide side panel stays open across tabs: no event.
        tab.sidePanel.scheduleRefresh()
    }

    /// `tab` shows in this turn with its input window out of the window: that window comes in after this turn's frame
    /// (`CEFLayerHosting.pageAppeared`). Asked when the tab's view appears (`present`) and when the content lifecycle
    /// reveals it (`CEFTab.setContentVisible`): a switch between two page tabs of a pane binds the incoming page's view
    /// before it reveals the tab, so `present` still saw the host hidden, the page took no hold, and the fork ordered
    /// its window in before the switch's commit (TAB SWITCH TAIL: 18 of 40 switches a refresh or more late, macOS 26.7).
    /// A host whose page window was out when the show began has no window in the window, whatever sits at its rect:
    /// in that switch the leaving page's window still fills the same page area.
    func holdFirstFrameIfAppeared(_ tab: CEFTab) { // perf-hot: 10ms tab-switch (every Chromium tab show)
        guard visibleTab === tab, tab.appearedThisTurn, !hostView.isHidden, tab.browserID != nil, !tab.awaitsWindowMove else { return }
        let windowInWindow = shownWithWindowOut !== tab && tab.pageWindow != nil
        // The hold's end grants the kept ask of the tab this host shows then (a tab switch in the hold).
        hostView.layerHosting.pageAppeared(windowInWindow: windowInWindow) { [weak self] in self?.visibleTab?.grantPendingFocusIfShown() }
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

/// Tab switch timeline marks (cx-asb1): wall-clock ms, so a bench can line
/// them up with the page's own clock. Debug level: nothing is written unless
/// a `log stream --level debug` reads category "tab-switch".
private let tabSwitchLog = Logger(subsystem: "com.cmuxterm.app.next", category: "tab-switch")
private func tabSwitchMark(_ name: String) {
    tabSwitchLog.debug("tab-switch \(name, privacy: .public) \(Date().timeIntervalSince1970 * 1_000, format: .fixed(precision: 3), privacy: .public)")
}
