public import CmuxBrowser
import CmuxCEF
import Foundation

/// Screenshots of hidden Chromium pages. A hidden page's host view is hidden,
/// so Chromium draws no frames and `Page.captureScreenshot` waits forever.
/// For a capture the host view is covered (`CEFHostView.isCoveredForCapture`:
/// one occlusion hole over the whole page, resized with it) and then
/// unhidden: Chromium sees the page visible and draws, nothing reaches the
/// screen. The pane's own show or hide during a capture wins.
extension CEFBrowserPage: BrowserPageHiddenCapturing {
    public func withContentVisibleForCapture<T>(_ body: () async throws -> T) async rethrows -> T {
        let host = browser.hostView
        // Only a page this pane hid needs it; a page in no window cannot draw either way.
        guard hiddenCapture.depth > 0 || (host.isHidden && !hiddenCapture.wantsVisible && host.window != nil) else {
            return try await body()
        }
        if hiddenCapture.depth == 0 {
            // Cover first, then show: the page never draws on screen.
            host.isCoveredForCapture = true
            host.isHidden = false
        }
        hiddenCapture.depth += 1
        defer {
            hiddenCapture.depth -= 1
            if hiddenCapture.depth == 0 {
                if !hiddenCapture.wantsVisible { host.isHidden = true }
                host.isCoveredForCapture = false
            }
        }
        return try await body()
    }

    /// The pane showed or hid the page while a capture ran: uncover it at
    /// once when shown, cover it again when hidden; the capture's end hides it.
    func captureVisibilityChanged(_ visible: Bool) {
        browser.hostView.isCoveredForCapture = !visible
    }
}
