public import CmuxBrowser
import AppKit
import CmuxCEF
import Foundation

/// Screenshots of hidden Chromium pages. A hidden page draws no frames, so
/// `Page.captureScreenshot` waits forever.
///
/// - A background tab (host view hidden in its pane's window): the host view
///   is covered (`CEFHostView.isCoveredForCapture`: one occlusion hole over the
///   whole page, resized with it) and unhidden. Chromium sees the page visible
///   and draws; nothing reaches the screen.
/// - A page in a background workspace (host view in no window): the host view
///   moves for the capture into a transparent, click-through window of the
///   page's size, covered the same way, then goes back to its container.
///
/// The pane's own show or hide during a capture wins.
extension CEFBrowserPage: BrowserPageHiddenCapturing {
    public func withContentVisibleForCapture<T>(_ body: () async throws -> T) async rethrows -> T {
        let host = browser.hostView
        if hiddenCapture.depth == 0 {
            if host.window == nil {
                beginOffscreenCapture(host)
            } else if host.isHidden, !hiddenCapture.wantsVisible {
                // Cover first, then show: the page never draws on screen.
                host.isCoveredForCapture = true
                host.isHidden = false
            } else {
                return try await body()
            }
        }
        hiddenCapture.depth += 1
        defer {
            hiddenCapture.depth -= 1
            if hiddenCapture.depth == 0 { endCapture(host) }
        }
        return try await body()
    }

    /// The pane showed or hid the page while a capture ran: uncover it at
    /// once when shown, cover it again when hidden; the capture's end hides it.
    func captureVisibilityChanged(_ visible: Bool) {
        // A page moved into the capture window stays covered: its pane is elsewhere.
        guard hiddenCapture.window == nil else { return }
        browser.hostView.isCoveredForCapture = !visible
    }

    private func beginOffscreenCapture(_ host: CEFHostView) {
        let size = host.frame.width >= 1 && host.frame.height >= 1 ? host.frame.size : NSSize(width: 1280, height: 800)
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        let window = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        hiddenCapture.window = window
        hiddenCapture.home = host.superview
        hiddenCapture.homeFrame = host.frame
        hiddenCapture.homeAutoresizing = host.autoresizingMask
        host.isCoveredForCapture = true
        host.removeFromSuperview()
        host.frame = window.contentView?.bounds ?? NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        host.isHidden = false
        window.contentView?.addSubview(host)
        // Shown without activating the app or taking the keyboard.
        window.orderFrontRegardless()
    }

    private func endCapture(_ host: CEFHostView) {
        if let window = hiddenCapture.window {
            host.removeFromSuperview()
            host.frame = hiddenCapture.homeFrame
            host.autoresizingMask = hiddenCapture.homeAutoresizing
            hiddenCapture.home?.addSubview(host)
            window.orderOut(nil)
            window.close()
            hiddenCapture.window = nil
            hiddenCapture.home = nil
        }
        if !hiddenCapture.wantsVisible { host.isHidden = true }
        host.isCoveredForCapture = false
    }
}
