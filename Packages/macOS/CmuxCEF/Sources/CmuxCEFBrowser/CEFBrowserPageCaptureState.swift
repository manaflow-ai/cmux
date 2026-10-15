import AppKit

/// A Chromium page's hidden-capture bookkeeping (CEFBrowserPage+HiddenCapture).
struct CEFBrowserPageCaptureState {
    /// Captures running now; the page is covered and drawing while above 0.
    var depth = 0
    /// What the pane last asked for with `setContentVisible`.
    var wantsVisible = true
    /// The transparent window a page in no window draws in during a capture.
    var window: NSWindow?
    /// Where that page's host view goes back to.
    weak var home: NSView?
    var homeFrame = NSRect.zero
    var homeAutoresizing: NSView.AutoresizingMask = []
}
