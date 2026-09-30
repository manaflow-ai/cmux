import AppKit
import Foundation

/// When cmux turns on the fork's popup windows. Fork API 11 (release
/// cmux.10) has them, but live on cmux.10 the attached window never shows
/// (it stays a hidden 86x64 window; the attach runs while the panel's view
/// is still 0x0) and its CMUX_POPUP_WINDOW_CREATED window id is not the id
/// chrome.windows returns (the fork reads the Browser's session id in its
/// constructor, before it is set). Until a fork release fixes both (API 13
/// or later), cmux keeps the older behavior: the window guard moves the
/// popup's tab into the panel through a pane window.
nonisolated enum CEFPopupWindows {
    static let minimumForkAPI = 13

    static func isEnabled(forkAPIVersion: Int) -> Bool { forkAPIVersion >= minimumForkAPI }
}

/// Extension popup windows (fork API 11). `chrome.windows.create({type:
/// "popup"})` makes a Chromium window of its own; the fork keeps it hidden
/// (it used to move its tab into a pane window and close it, so the window
/// id the extension got stopped working). cmux shows it in the floating
/// popup panel, like a sized `window.open` popup, but instead of moving the
/// tab into a new window, the popup host attaches the extension's own
/// window to its view (`cmux_popup_window_attach`). The window id then stays
/// valid until the panel closes; `chrome.windows.update` bounds resize the
/// panel (`.resizePopup`) and `chrome.windows.remove` closes the tab, which
/// closes the panel.
extension CEFPaneHost {
    /// A popup host for window `window` holding its tab `browser`, announced
    /// by `opener` (a pane's visible tab) as `.openPopup`.
    func adoptPopupWindow(window: Int32, browser: Int32, bounds: CGRect?, opener: CEFTab) {
        let id = BrowserTabID.random()
        let popupKey = CEFPaneKey(pane: BrowserPaneID(rawValue: Self.popupPrefix + id.rawValue),
                                  profile: key.profile, machineKey: key.machineKey, offTheRecord: key.offTheRecord)
        let host = runtime.host(for: popupKey)
        host.popupWindow = window
        let tab = CEFTab(id: id, profile: key.profile, host: host, runtime: runtime)
        tab.machineStore = opener.machineStore
        tab.navigationGuard = opener.navigationGuard
        tab.popupOpenerHost = self
        host.add(tab)
        runtime.register(tab, browser: browser)
        tab.reachedFirstRealPage()
        tab.inheritDelegates(from: opener)
        opener.emit(.openPopup(tab, BrowserPopupRequest(features: bounds)))
    }

    /// The panel shows the popup: the hidden window is attached over this
    /// host's view (never inside a Chromium event; this runs from the view
    /// lifecycle). Returns true when this call handled `tab`. A window that
    /// cannot attach closes its tab, so no hidden window stays behind.
    func attachPopupWindowIfNeeded(_ tab: CEFTab) -> Bool {
        guard let popupWindow, case .none = window, let shim = runtime.shim else { return false }
        guard let browser = tab.browserID, hostView.window != nil else {
            BrowserLifecycleTrace.record(tab.id, "popup-window-attach deferred browser=\(tab.browserID ?? 0) window=\(hostView.window != nil)")
            return true
        }
        let size = hostView.bounds.size
        BrowserLifecycleTrace.record(tab.id, "popup-window-attach window=\(popupWindow) size=\(Int(size.width))x\(Int(size.height))")
        if shim.popupWindowAttach(popupWindow, Unmanaged.passUnretained(hostView).toOpaque(),
                                  max(size.width, 1).clampedInt32, max(size.height, 1).clampedInt32) == 1 {
            window = .live(window: popupWindow)
            lastActivated = browser
            _ = shim.tabActivate(browser)
            hostView.postGeometryChange()
            BrowserLifecycleTrace.record(tab.id, "popup-window-attached")
        } else {
            runtime.logger.error("CEF popup window \(popupWindow) did not attach; closing its tab")
            tab.close()
        }
        return true
    }
}

extension CEFRuntime {
    /// CMUX_POPUP_WINDOW_CREATED: runs on the next main-actor turn (the
    /// event arrives inside Chromium's window creation).
    func popupWindowCreated(window: Int32, browser: Int32) {
        Task { @MainActor [weak self] in self?.adoptPopupWindow(window: window, browser: browser) }
    }

    private func adoptPopupWindow(window: Int32, browser: Int32) {
        guard browser != 0, tabsByBrowser[browser] == nil, !adoptions.isClosed(browser) else { return }
        unplaced[browser] = nil
        guard let opener = lastShownHost?.visibleTab else {
            // No cmux window to show it over: close it (chrome.windows sees
            // the window removed).
            logger.error("CEF popup window \(window) has no pane to open over; closing it")
            shim?.close(browser)
            return
        }
        opener.host.adoptPopupWindow(window: window, browser: browser, bounds: popupWindowBounds(window), opener: opener)
    }

    /// CMUX_POPUP_WINDOW_BOUNDS (chrome.windows.update): the panel follows.
    func popupWindowBoundsChanged(window: Int32) {
        guard let host = hosts.values.first(where: { $0.popupWindow == window }), let tab = host.visibleTab ?? host.tabs.first,
              let bounds = popupWindowBounds(window) else { return }
        tab.emit(.resizePopup(BrowserPopupRequest(features: bounds)))
    }

    /// Screen DIPs from the top-left of the primary display, as window
    /// features are.
    private func popupWindowBounds(_ window: Int32) -> CGRect? {
        guard let shim else { return nil }
        var x: Int32 = 0, y: Int32 = 0, width: Int32 = 0, height: Int32 = 0
        guard shim.popupWindowBounds(window, &x, &y, &width, &height) == 1 else { return nil }
        return CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }
}
