import AppKit

/// A resize gap in the page's own color. When a Chromium page's window or
/// pane changes size, Chromium's frame at the new size arrives some frames
/// later; until then the page window shows its last frame, anchored top-left
/// (Chromium's flipped layer tree), and a gap to its right or below it. That
/// gap is Chromium's page background where its compositor already drew the
/// new size, and the host view under the page window where it did not. Both
/// take the page's own background (`pageBackdropARGB`), sampled from the
/// document when it loads and again when a live resize starts, so the gap
/// reads as more page instead of white or the window backdrop
/// (`BrowserResizeTunables.pageBackdrop`).
extension CEFTab {
    /// The document's background as `[r, g, b]` (0-255): the root element's,
    /// else the body's (CSS propagates it to the canvas); white when neither
    /// has one; null when the first one set is translucent (Chromium's white
    /// base stays, since the page paints its color over that base). A 1x1
    /// canvas turns any CSS color syntax into sRGB bytes.
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
        // Translucent: the page paints it over Chromium's base, so a base of the same color would darken it.
        return a === 255 ? [r, g, b] : null;
      }
      return [255, 255, 255];
    })()
    """

    /// `[r, g, b]` from `pageBackdropScript` as opaque 0xAARRGGBB; nil for
    /// anything else.
    nonisolated static func backdropARGB(from value: BrowserJSValue) -> UInt32? {
        guard case .array(let parts) = value, parts.count == 3 else { return nil }
        var argb: UInt32 = 0xFF00_0000
        for (index, part) in parts.enumerated() {
            guard case .number(let number) = part, number.isFinite else { return nil }
            argb |= UInt32(min(max(number.rounded(), 0), 255)) << (16 - 8 * UInt32(index))
        }
        return argb
    }

    /// The page's background color for the host view, nil when the gap
    /// keeps the pane ground: before the first real page (the New Tab page
    /// is a hole that shows the window backdrop), or with the tunable off.
    /// A document that has not settled yet takes the loading base, so the gap
    /// matches the page area (`CEFTab+LoadingBackground`).
    var pageBackdropColor: CGColor? {
        guard BrowserResizeTunables.pageBackdrop.value, pastFirstRealPage else { return nil }
        let argb = loadingBaseARGB ?? pageBackdropARGB ?? PageBackground.engineDefaultARGB
        func channel(_ shift: UInt32) -> CGFloat { CGFloat((argb >> shift) & 0xFF) / 255 }
        return CGColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
    }

    /// Reads the document's background (after a load, and when a live resize
    /// starts) and applies it to Chromium's page background and the host view.
    func samplePageBackdrop() {
        guard BrowserResizeTunables.pageBackdrop.value, pastFirstRealPage, browserID != nil, !isClosed else { return }
        let document = pageBackdropDocument
        Task { [weak self] in
            guard let value = try? await self?.evaluate(Self.pageBackdropScript, world: .page, gesture: .cmux) else { return }
            // A navigation since the read: the next document samples its own.
            guard let self, document == self.pageBackdropDocument, !self.isClosed else { return }
            let argb = Self.backdropARGB(from: value)
            guard argb != self.pageBackdropARGB else { return }
            self.pageBackdropARGB = argb
            self.applyPageBackground()
        }
    }

    /// A new document committed: its background is unknown until it loads, so
    /// the loading base applies again (a page without a background of its own
    /// must never show the previous page's color).
    func resetPageBackdrop() {
        pageBackdropDocument += 1
        let settled = documentSettled
        documentSettled = false
        guard pageBackdropARGB != nil || settled else { return }
        pageBackdropARGB = nil
        applyPageBackground()
    }
}
