public import CmuxBrowser
import CmuxCEF
import Foundation

/// Screenshots of hidden Chromium pages. A hidden page's host view is hidden,
/// so Chromium draws no frames and `Page.captureScreenshot` waits forever.
/// For a capture, the page is first covered by an occlusion hole over its
/// whole host view (the fork's way to keep a page from showing), then
/// unhidden: Chromium sees it visible and draws, nothing reaches the screen.
extension CEFBrowserPage: BrowserPageHiddenCapturing {
    public func withContentVisibleForCapture<T>(_ body: () async throws -> T) async rethrows -> T {
        if hiddenCapture.depth == 0 {
            // A page on screen needs nothing.
            guard browser.hostView.isHidden else { return try await body() }
            let host = browser.hostView
            hiddenCapture.savedOcclusion = host.occlusionRects
            // Cover first, then show: the page never draws on screen.
            host.occlusionRects = [host.bounds]
            host.isHidden = false
        }
        hiddenCapture.depth += 1
        defer {
            hiddenCapture.depth -= 1
            if hiddenCapture.depth == 0 { endHiddenCapture() }
        }
        return try await body()
    }

    /// The pane showed or hid the page while a capture ran: uncover it at
    /// once when shown, cover it again when hidden; the capture's end hides it.
    func captureVisibilityChanged(_ visible: Bool) {
        let host = browser.hostView
        host.occlusionRects = visible ? hiddenCapture.savedOcclusion : [host.bounds]
    }

    /// The last capture ended: a page the pane hides is hidden again.
    private func endHiddenCapture() {
        let host = browser.hostView
        if !hiddenCapture.wantsVisible { host.isHidden = true }
        host.occlusionRects = hiddenCapture.savedOcclusion
    }
}
