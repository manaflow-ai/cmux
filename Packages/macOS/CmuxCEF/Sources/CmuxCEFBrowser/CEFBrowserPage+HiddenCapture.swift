public import CmuxBrowser
import CmuxCEF
import Foundation

/// Screenshots of hidden Chromium pages. A hidden page's host view is hidden,
/// or in no window (its pane is in a workspace that has not been on screen),
/// so Chromium draws no frames and `Page.captureScreenshot` waits forever.
/// For a capture, a page in no window moves into an off-screen window
/// (``CEFCaptureRenderWindow``); a hidden page is first covered by an
/// occlusion hole over its whole host view (the fork's way to keep a page
/// from showing), then unhidden: Chromium sees it visible and draws, nothing
/// reaches the screen.
extension CEFBrowserPage: BrowserPageHiddenCapturing {
    public func withContentVisibleForCapture<T>(_ body: () async throws -> T) async rethrows -> T {
        if hiddenCapture.depth == 0 {
            let host = browser.hostView
            let inWindow = host.window != nil
            // A page on screen needs nothing.
            guard host.isHidden || !inWindow else { return try await body() }
            hiddenCapture.savedOcclusion = host.occlusionRects
            if !inWindow { hiddenCapture.renderWindow = CEFCaptureRenderWindow(parking: contentView) }
            if host.isHidden {
                // Cover first, then show: the page never draws on screen.
                host.occlusionRects = [host.bounds]
                host.isHidden = false
            }
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

    /// The last capture ended: a page the pane hides is hidden again, and a
    /// parked page goes back to its pane.
    private func endHiddenCapture() {
        let host = browser.hostView
        if !hiddenCapture.wantsVisible { host.isHidden = true }
        host.occlusionRects = hiddenCapture.savedOcclusion
        hiddenCapture.renderWindow?.restore()
        hiddenCapture.renderWindow = nil
    }
}
