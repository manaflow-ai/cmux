public import AppKit

/// What a window image (`debug.window_snapshot`, `cmux window screenshot`) needs of the React
/// pages a window shows on the Chromium engine. Chromium's GPU process draws such a page into its
/// own child window, which the window server leaves out of an app's image of its window unless
/// the app has the Screen Recording grant (capture slots do not), so the image paints Chromium's
/// own image of each page over its area, as it does for browser tabs.
extension PageWebView {
    /// The page as Chromium drew it (`Page.captureScreenshot`); nil on a WebKit page, on a page that
    /// is discarded or still shows its discard snapshot (the window's own image has that layer), or
    /// when Chromium gives no image.
    public func chromiumImage() async -> CGImage? {
        guard !isDiscarded, !showsDiscardSnapshot, let session = chromiumSession,
              let json = try? await session.page.devTools("Page.captureScreenshot", params: ["format": "png"]) else { return nil }
        return await Self.capturedPageImage(json, on: session.work)
    }
}

extension PageRegistry {
    /// The Chromium pages `window` shows (in it, not hidden, not transparent, not the pool's
    /// parked spare, not behind its discard snapshot, which is in the window's own image), each
    /// with its area in window coordinates, oldest first. A page under
    /// an alpha-0 view (the New Tab spare's off-screen parking, a pane holding its paint) or
    /// outside the window's content is not shown.
    public func shownChromiumPages(in window: NSWindow) -> [(page: PageWebView, rect: NSRect)] {
        let content = window.contentView.map { $0.convert($0.bounds, to: nil) } ?? .zero
        return self.pages().compactMap { page in
            guard page.chromiumSession != nil, page.window === window, !page.isParkedSpare, !page.showsDiscardSnapshot,
                  !page.isHiddenOrHasHiddenAncestor, !Self.isTransparent(page) else { return nil }
            let rect = page.convert(page.bounds, to: nil)
            return rect.width > 0 && rect.height > 0 && rect.intersects(content) ? (page, rect) : nil
        }
    }

    /// ``shownChromiumPages(in:)`` of ``processWide`` (removed by p13-webui-010).
    public static func shownChromiumPages(in window: NSWindow) -> [(page: PageWebView, rect: NSRect)] {
        processWide.shownChromiumPages(in: window)
    }

    private static func isTransparent(_ view: NSView) -> Bool {
        sequence(first: view, next: \.superview).contains { $0.alphaValue == 0 }
    }
}
