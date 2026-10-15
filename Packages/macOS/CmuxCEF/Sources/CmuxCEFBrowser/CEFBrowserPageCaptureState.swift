/// A Chromium page's hidden-capture bookkeeping (CEFBrowserPage+HiddenCapture).
struct CEFBrowserPageCaptureState: Equatable {
    /// Captures running now; the page is covered and unhidden while above 0.
    var depth = 0
    /// What the pane last asked for with `setContentVisible`.
    var wantsVisible = true
}
