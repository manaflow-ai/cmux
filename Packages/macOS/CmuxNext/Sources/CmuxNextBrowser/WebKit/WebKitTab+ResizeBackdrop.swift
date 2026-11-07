public import AppKit
import WebKit

/// A resize gap in the page's own color, the WebKit half of `CEFTab+ResizeBackdrop` (#36520). When a WebKit page's pane
/// changes size its web view takes the new frame in the same frame (`WebKitPageContainer+PaneMotion`) and WebKit draws the
/// new size some frames later; until then the web view's own layer background shows beside the last frame. WebKit paints
/// that layer white, or the dark control color in a dark appearance, so a dark page showed a light gap: the layer takes the
/// document's background instead, read when it finishes loading and when a key resize starts. At rest the page covers it.
///
/// macOS has no public switch for that color: this calls WebKit's `_setBackgroundColor:` SPI, checked first; without it the
/// web view keeps WebKit's default. It colors only the view's own layer, never the document's base, so a page with no
/// background of its own looks as before. While the loading background holds (`WebKitTab+LoadingBackground`) WebKit paints
/// that layer clear whatever this color is.
extension WebKitTab {
    // crash-allow: a string selector traps only when sent unanswered; every send below checks responds(to:) first and skips it on a WebKit without the setter (as WebKitGestureFreeEvaluation).
    private static var setBackgroundColor: Selector { NSSelectorFromString("_setBackgroundColor:") }

    /// The document's background as `[r, g, b]` (0-255): the root element's, else the body's; when neither has one,
    /// `"dark"` or `"light"`, the canvas WebKit paints for the document's color scheme
    /// (`PageBackground.usesDarkCanvasScript`; the web view keeps WebKit's own default then, so the gap keeps the
    /// canvas); null when the first one set is translucent. `CEFTab.pageBackdropScript` with the canvas named, not
    /// painted.
    static let pageBackdropScript = """
    (() => {
      const canvas = document.createElement('canvas');
      canvas.width = canvas.height = 1;
      const context = canvas.getContext('2d', { willReadFrequently: true });
      for (const element of [document.documentElement, document.body]) {
        if (!element) continue;
        context.clearRect(0, 0, 1, 1);
        context.fillStyle = 'rgba(0, 0, 0, 0)';
        context.fillStyle = getComputedStyle(element).backgroundColor;
        context.fillRect(0, 0, 1, 1);
        const [r, g, b, a] = context.getImageData(0, 0, 1, 1).data;
        if (a === 0) continue;
        return a === 255 ? [r, g, b] : null;
      }
      return \(PageBackground.usesDarkCanvasScript) ? 'dark' : 'light';
    })()
    """

    /// Reads the document's background (`pageBackdropScript`, in the isolated world: a page cannot patch what it reads)
    /// and gives it to the web view: when the document loads, when a key resize starts and when the appearance changes.
    func samplePageBackdrop() {
        guard !isClosed, !PageBackground.isBlank(webView.url),
              webView.responds(to: Self.setBackgroundColor) else { return }
        let document = pageBackdropDocument
        Task { [weak self] in
            guard let value = try? await self?.evaluate(Self.pageBackdropScript, world: .isolated, gesture: .cmux) else { return }
            // A navigation since the read: the next document reads its own.
            guard let self, document == self.pageBackdropDocument, !self.isClosed else { return }
            if case .string(let canvas) = value { self.pageCanvasDark = canvas == "dark" } else { self.pageCanvasDark = false }
            self.applyPageBackdrop(CEFTab.backdropARGB(from: value))
        }
    }

    /// A new document committed: its color is unknown until it loads, so WebKit's default applies again (a page must
    /// never show the previous page's color).
    func resetPageBackdrop() {
        pageBackdropDocument += 1
        pageCanvasDark = false
        applyPageBackdrop(nil)
    }

    /// `argb` (nil: WebKit's default, also for a translucent document background) as the web view's own background.
    private func applyPageBackdrop(_ argb: UInt32?) {
        guard argb != pageBackdropARGB, webView.responds(to: Self.setBackgroundColor) else { return }
        pageBackdropARGB = argb
        webView.perform(Self.setBackgroundColor, with: argb.map(Self.pageColor))
    }

    /// The ground the page's pane shows when it closes (CLOSE MOTION 2 case 3, CLOSE GROUND FIX): what the page area
    /// paints, by the rule Chromium's tab uses (`PageBackground.closingGroundARGB`). No real page, or the loading hold
    /// (WebKit draws no background, so the chrome shows): nil, the chrome's ground. Then the document's background as
    /// read, else WebKit's canvas (white, dark under a dark color scheme), never the window's color.
    public var pageGround: CGColor? {
        PageBackground.closingGroundARGB(
            realPage: !PageBackground.isBlank(webView.url), settled: !pageBaseHold.isScheduled, loading: nil,
            document: pageBackdropARGB,
            canvas: pageCanvasDark ? PageBackground.webKitDarkCanvasARGB : PageBackground.engineDefaultARGB
        ).map(PageBackground.cgColor)
    }

    /// Opaque 0xAARRGGBB as an sRGB color.
    nonisolated static func pageColor(_ argb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255,
                blue: CGFloat(argb & 0xFF) / 255, alpha: 1)
    }
}
