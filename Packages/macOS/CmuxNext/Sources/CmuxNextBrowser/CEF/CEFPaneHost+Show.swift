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
