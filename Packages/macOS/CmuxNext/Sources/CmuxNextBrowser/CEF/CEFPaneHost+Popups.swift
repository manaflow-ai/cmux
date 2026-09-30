import AppKit
import Foundation

/// Sized popups (`window.open` with window features, OAuth sign-in,
/// `chrome.windows.create({type: 'popup'})`) are shown in a floating panel
/// by the host app. A Chromium window shows one tab, so the popup cannot
/// stay a tab of its opener's window (the opener's pane would show the
/// popup, or go blank): it gets a popup host of its own, whose window is
/// created with an about:blank placeholder when the panel first shows the
/// popup; the popup then moves into it (`cmux_tab_move_to_window` keeps the
/// WebContents, so `window.opener` and `postMessage` keep working) and the
/// placeholder closes.
extension CEFPaneHost {
    static let popupPrefix = "popup-"

    var isPopupHost: Bool { key.pane.rawValue.hasPrefix(Self.popupPrefix) }

    /// Chromium inserted popup `browser` into this window as its foreground
    /// tab. It becomes a page of its own popup host (same profile and
    /// store), announced by the opener as `.openPopup`.
    func adoptPopup(browser: Int32, bounds: CGRect?, opener: CEFTab?) {
        let id = BrowserTabID.random()
        let popupKey = CEFPaneKey(pane: BrowserPaneID(rawValue: Self.popupPrefix + id.rawValue),
                                  profile: key.profile, machineKey: key.machineKey, offTheRecord: key.offTheRecord)
        let host = runtime.host(for: popupKey)
        let tab = CEFTab(id: id, profile: key.profile, host: host, runtime: runtime)
        tab.machineStore = opener?.machineStore
        tab.navigationGuard = opener?.navigationGuard ?? .none
        tab.awaitsWindowMove = true
        tab.popupOpenerHost = self
        host.add(tab)
        runtime.register(tab, browser: browser)
        tab.inheritDelegates(from: opener)
        // Chromium made the popup this window's active tab. Show the opener
        // again on the next turn (this may run inside Chromium's tab
        // insertion, which forbids tab strip changes).
        Task { @MainActor [weak self] in self?.reactivateVisibleTab() }
        opener?.emit(.openPopup(tab, BrowserPopupRequest(features: bounds)))
    }

    /// Makes the tab this host shows Chromium's active tab again.
    func reactivateVisibleTab() {
        guard let visible = visibleTab, !visible.awaitsWindowMove, let browser = visible.browserID else { return }
        lastActivated = browser
        _ = runtime.shim?.tabActivate(browser)
    }

    /// The panel shows a popup that is still in its opener's window: create
    /// this host's window with a placeholder (`windowCreated` then moves the
    /// popup in). A live window takes it at once.
    func ensureOwnWindow(for tab: CEFTab) {
        switch window {
        case .live:
            Task { @MainActor [weak self] in self?.movePopupsIn() }
        case .creating:
            break
        case .none:
            let blank = CEFTab(id: .random(), profile: key.profile, host: self, runtime: runtime)
            blank.machineStore = tab.machineStore
            blank.navigationGuard = tab.navigationGuard
            placeholder = blank
            add(blank)
            ensureCreated(blank)
        }
    }

    /// Moves every popup waiting in its opener's window into this host's
    /// live window, shows the visible one, closes the placeholder, and lets
    /// the openers show their own pages again. A popup that cannot move
    /// (fork without `cmux_tab_move_to_window`) closes rather than take over
    /// its opener's pane.
    func movePopupsIn() {
        guard case .live = window, let shim = runtime.shim, let anchor = anchorBrowser else { return }
        var openers: [CEFPaneHost] = []
        for tab in tabs where tab.awaitsWindowMove {
            guard let browser = tab.browserID else { continue }
            if shim.tabMoveToWindow(browser, anchor, -1) == 1 {
                tab.awaitsWindowMove = false
                if let opener = tab.popupOpenerHost { openers.append(opener) }
            } else {
                runtime.logger.error("CEF popup \(browser) could not move into its own window; closing it")
                tab.close()
            }
        }
        if let visible = visibleTab, !visible.awaitsWindowMove, let browser = visible.browserID {
            lastActivated = browser
            _ = shim.tabActivate(browser)
            hostView.postGeometryChange()
        }
        if let blank = placeholder, tabs.contains(where: { $0 !== blank && !$0.awaitsWindowMove && $0.browserID != nil }) {
            placeholder = nil
            blank.close()
        }
        for opener in openers { opener.reactivateVisibleTab() }
    }
}
