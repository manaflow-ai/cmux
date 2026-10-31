public import AppKit

/// Native UI over a Chromium page (``PageWebView/nativeRects``). A Chromium page is a child window
/// above the whole host window, so a native view laid over the page (a chat's pane tabs while the
/// chat shares the tab row) would hide under it: the page window leaves these rects uncovered
/// (``PageChromiumPage/occlusionRects``), and the native view shows there and takes the mouse.
extension PageWebView {
    /// Hands ``nativeRects`` to the Chromium page that shows the document, in its content view's
    /// coordinates; nothing on WebKit. Runs when the rects change, when a Chromium page attaches,
    /// and when this view's size changes (the content view is not flipped, so its rects move).
    func applyNativeRects() {
        guard let page = chromiumSession?.page else { return }
        let content = page.contentView
        let rects = nativeRects.compactMap { rect -> CGRect? in
            let clipped = rect.intersection(bounds)
            return clipped.isNull || clipped.isEmpty ? nil : convert(clipped, to: content)
        }
        if page.occlusionRects != rects { page.occlusionRects = rects }
    }
}
