import AppKit
import CmuxNextWakeups

/// The page view's display (task 221 of plans/cmux-next/chrome-parity/p01-process.md). Chrome's page
/// view re-reads its screen when its window changes screen or backing properties and when the
/// displays change, and tells its host only when the screen infos differ
/// (`-[RenderWidgetHostViewCocoa updateScreenProperties]`,
/// content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm). This view does the same:
/// `viewDidMoveToWindow`, `viewDidChangeBackingProperties`, the window's
/// `didChangeScreenNotification` and `didChangeScreenProfileNotification`, and
/// ``screenParametersChanged()`` from ``CEFRuntime``'s one display-change observer.
extension ChromiumHostPageView {
    /// Re-reads the window's display and places the page there when it differs from the display
    /// last placed; nothing while nobody takes it.
    func screenMayHaveChanged() {
        guard onScreenInfo != nil, let window else { return }
        screenInfo = screenInfoSource(window)
        placeIfNeeded()
    }

    /// Places the page on the display last read when no placement for it went out yet: one
    /// comparison when it did. A placement the taker could not send (no page shown in the view yet,
    /// a view below 1 x 1 point) is not recorded, so the next chance sends it.
    func placeIfNeeded() {
        guard let onScreenInfo, let screenInfo, screenInfo != placedScreenInfo else { return }
        if onScreenInfo(screenInfo) { placedScreenInfo = screenInfo }
    }

    /// A display was added, removed or changed its mode, scale or arrangement
    /// (`NSApplication.didChangeScreenParametersNotification`, observed once by ``CEFRuntime``).
    func screenParametersChanged() {
        screenMayHaveChanged()
    }

    /// What the host places the page's detached window with: the reported display and the view's
    /// origin on it; nil before a display was reported or out of every window.
    var pageDisplay: ChromiumHostPageDisplay? {
        guard let screenInfo, let origin = presentedScreenRect?.origin else { return nil }
        return ChromiumHostPageDisplay(displayID: screenInfo.displayID, screenX: Double(origin.x), screenY: Double(origin.y))
    }

    /// Follows the window's screen notices only while someone takes the display.
    func observeScreen() {
        guard onScreenInfo != nil, let window else {
            screenEvents = []
            return
        }
        let events = WindowEvents.of(window, center: windowEventCenter)
        let reread: @MainActor () -> Void = { [weak self] in self?.screenMayHaveChanged() }
        screenEvents = [
            events.subscribe(NSWindow.didChangeScreenNotification, owner: "ChromiumHostPageView.screen", reread),
            events.subscribe(NSWindow.didChangeScreenProfileNotification, owner: "ChromiumHostPageView.screen", reread),
        ]
    }
}

extension CEFRuntime {
    /// Host mode: places `browser`'s detached page window on the display `page` shows on, at its
    /// origin there, so Chromium's begin-frames tick at that display's rate and the page takes its
    /// scale and color space (`cmux_shim_browser_set_page_display`, a view op the host runs in order).
    /// Chrome's browser process moves its widget's display the same way when the app shim reports it
    /// (`NativeWidgetMacNSWindowHost::OnWindowDisplayChanged`,
    /// ui/views/cocoa/native_widget_mac_ns_window_host.mm). Nothing below fork API 31 or before
    /// the page view read a display; it places the page when it does. True when the placement went
    /// out, which the page view records (``ChromiumHostPageView/placedScreenInfo``).
    @discardableResult
    func placeHostedPage(_ page: ChromiumHostPageView, browser: Int32) -> Bool {
        guard forkAPIVersion >= ChromiumHostScreenInfo.forkAPI, let display = page.pageDisplay, let shim else { return false }
        _ = shim.browserSetPageDisplay(browser, display.displayID, display.screenX, display.screenY)
        page.placedScreenInfo = page.screenInfo
        return true
    }
}
