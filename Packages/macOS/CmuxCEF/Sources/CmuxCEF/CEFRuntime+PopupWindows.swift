import AppKit
import Foundation

/// Extension popup windows (fork API 13). `chrome.windows.create({type:
/// "popup"})` makes a Chromium window of its own; the fork keeps it hidden
/// (it used to move its tab into a pane window and close it, so the window
/// id the extension got stopped working). cmux hands its tab to the page
/// shown last as a sized popup (`.newBrowser` with `.newPopup`), which the
/// app shows in its popup window; when that window shows the page, the
/// extension's own window attaches over the page's host view
/// (`cmux_shim_popup_window_attach`). The window id then stays valid until
/// the popup closes; `chrome.windows.update` bounds reach the page as
/// `.popupWindowBoundsRequested` and `chrome.windows.remove` closes the tab,
/// which closes the popup.
///
/// Reference: cmux Next `CmuxNextBrowser/CEF/CEFPaneHost+PopupWindows.swift`.
extension CEFRuntime {
    /// CMUX_POPUP_WINDOW_CREATED: adopts on the next main-actor turn (the
    /// event arrives inside Chromium's window creation). `browser` is 0 when
    /// the window has no tab yet; its tab's AFTER_CREATED adopts it then.
    func popupWindowCreated(window: Int32, browser: Int32, type: Int = 0) {
        notePopupWindow("created window=\(window) browser=\(browser) type=\(type)")
        keptPopupWindows.insert(window)
        guard browser != 0 else { return }
        // Its tab's AFTER_CREATED (no opener) may have arrived in this same
        // turn: that orphan decision must not close it.
        deferredOrphans.remove(browser)
        Task { @MainActor [weak self] in self?.adoptPopupWindow(window: window, browser: browser) }
    }

    /// A tab created without a known opener while popup windows are on: the
    /// tab of a popup window is adopted, any other one closes as before.
    func deferOrphan(_ id: Int32, created: CEFCreatedBy) {
        deferredOrphans.insert(id)
        Task { @MainActor [weak self] in self?.resolveOrphan(id, created: created) }
    }

    func resolveOrphan(_ id: Int32, created: CEFCreatedBy) {
        // Closed meanwhile, or adopted by its CMUX_POPUP_WINDOW_CREATED.
        guard deferredOrphans.remove(id) != nil, browsers[id] == nil else { return }
        let window = shim?.tabWindowID(id) ?? 0
        if window != 0, keptPopupWindows.contains(window) || popupWindowBounds(window) != nil {
            adoptPopupWindow(window: window, browser: id)
        } else {
            closeOrphan(id, created: created)
        }
    }

    /// The page a popup window opens over: the page shown last, else any
    /// shown page, else any live page.
    func popupWindowOpener() -> CEFBrowser? {
        if let last = lastShownBrowser, !last.isClosed, last.browserID != nil { return last }
        let live = browsers.values.filter { !$0.isClosed && !$0.isPlaceholder && $0.popupWindow == nil }
        return live.first { $0.hostView.window != nil } ?? live.first
    }

    func adoptPopupWindow(window: Int32, browser: Int32) {
        deferredOrphans.remove(browser)
        guard browser != 0, browsers[browser] == nil, !closedUnregistered.contains(browser) else {
            notePopupWindow("window=\(window) browser=\(browser) skipped: known=\(browsers[browser] != nil) "
                            + "closed=\(closedUnregistered.contains(browser))")
            return
        }
        guard let opener = popupWindowOpener() else {
            // No cmux page to show it over: close it (chrome.windows sees
            // the window removed).
            logger.error("CEF popup window \(window) has no page to open over; closing it")
            notePopupWindow("window=\(window) browser=\(browser) closed: no opener")
            shim?.close(browser)
            return
        }
        // The page may have loaded before this adoption (its address and
        // title events reached no page): start from its current entry.
        let entry = shim.flatMap { $0.takeString($0.tabNavigationEntries(browser)) }
            .flatMap(CEFPopupWindows.currentEntry(navigationEntriesJSON:))
        let popup = CEFBrowser(adoptingPopupWindow: window, browser: browser, from: opener, runtime: self,
                               url: entry?.url, title: entry?.title ?? "")
        register(popup, id: browser)
        notePopupWindow("window=\(window) browser=\(browser) adopted url=\(entry?.url.absoluteString ?? "none")")
        // An extension opened it on purpose: the opener's popup policy sees a gesture.
        opener.emit(.newBrowser(popup, disposition: .newPopup, features: popupWindowBounds(window), userGesture: true))
    }

    /// CMUX_POPUP_WINDOW_BOUNDS (chrome.windows.update): the popup follows.
    func popupWindowBoundsChanged(window: Int32) {
        guard let popup = browsers.values.first(where: { $0.popupWindow == window }),
              let bounds = popupWindowBounds(window) else { return }
        guard !CEFPopupWindows.isOwnPlacement(bounds, hostFrame: popup.hostView.screenFrameFromTop) else { return }
        notePopupWindow("window=\(window) bounds \(Int(bounds.width))x\(Int(bounds.height))")
        popup.emit(.popupWindowBoundsRequested(bounds))
    }

    /// Screen DIPs from the top-left of the primary display, as window
    /// features are; nil when `window` is not a kept popup window.
    func popupWindowBounds(_ window: Int32) -> CGRect? {
        guard let shim else { return nil }
        var x: Int32 = 0, y: Int32 = 0, width: Int32 = 0, height: Int32 = 0
        guard shim.popupWindowBounds(window, &x, &y, &width, &height) == 1 else { return nil }
        return CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }

    /// The latest popup window events, oldest first (diagnostics).
    public var popupWindowLog: [String] { popupWindowEvents }

    func notePopupWindow(_ event: String) {
        popupWindowEvents.append(event)
        if popupWindowEvents.count > 12 { popupWindowEvents.removeFirst(popupWindowEvents.count - 12) }
    }
}

extension NSView {
    /// This view's frame in screen DIPs from the primary display's top-left
    /// (Chromium's screen coordinates), or nil outside a window.
    var screenFrameFromTop: CGRect? {
        guard let window, let primary = NSScreen.screens.first else { return nil }
        let frame = window.convertToScreen(convert(bounds, to: nil))
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }
}
