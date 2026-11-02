public import AppKit
import ImageIO

/// What a window image (`debug.window_snapshot`, `cmux window screenshot`) needs of the React
/// pages a window shows on the Chromium engine. Chromium's GPU process draws such a page into its
/// own child window, which the window server leaves out of an app's image of its window unless
/// the app has the Screen Recording grant (capture slots do not), so the image paints Chromium's
/// own image of each page over its area, as it does for browser tabs.
extension PageWebView {
    /// The page as Chromium drew it (`Page.captureScreenshot`); nil on a WebKit page or when
    /// Chromium gives no image.
    public func chromiumImage() async -> CGImage? {
        guard let page = chromiumSession?.page,
              let json = try? await page.devTools("Page.captureScreenshot", params: ["format": "png"]),
              let object = ChromiumPageHostWire.object(json), let base64 = object["data"] as? String,
              let png = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Where the page window leaves native UI uncovered (``nativeRects``, as the Chromium page
    /// holds them), in window coordinates: a window image paints the page's image everywhere else,
    /// as the screen shows it. Empty on a WebKit page.
    public var chromiumWindowHoles: [CGRect] {
        guard let page = chromiumSession?.page else { return [] }
        return page.occlusionRects.map { page.contentView.convert($0, to: nil) }
    }
}

extension PageRegistry {
    /// The Chromium pages `window` shows (in it, not hidden, not transparent, not the pool's
    /// parked spare), each with its area in window coordinates, oldest first. A page under
    /// an alpha-0 view (the New Tab spare's off-screen parking, a pane holding its paint) or
    /// outside the window's content is not shown.
    public static func shownChromiumPages(in window: NSWindow) -> [(page: PageWebView, rect: NSRect)] {
        let content = window.contentView.map { $0.convert($0.bounds, to: nil) } ?? .zero
        return pages().compactMap { page in
            guard page.chromiumSession != nil, page.window === window, !page.isParkedSpare,
                  !page.isHiddenOrHasHiddenAncestor, !isTransparent(page) else { return nil }
            let rect = page.convert(page.bounds, to: nil)
            return rect.width > 0 && rect.height > 0 && rect.intersects(content) ? (page, rect) : nil
        }
    }

    private static func isTransparent(_ view: NSView) -> Bool {
        sequence(first: view, next: \.superview).contains { $0.alphaValue == 0 }
    }
}
