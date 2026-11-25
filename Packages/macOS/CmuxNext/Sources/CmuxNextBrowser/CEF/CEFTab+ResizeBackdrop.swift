public import AppKit

/// A resize gap in the page's own color. When a Chromium page's window or
/// pane changes size, Chromium's frame at the new size arrives some frames
/// later; until then the page window shows its last frame, anchored top-left
/// (Chromium's flipped layer tree), and a gap to its right or below it. That
/// gap is Chromium's page background where its compositor already drew the
/// new size, and the host view under the page window where it did not. Both
/// take the page's own background (`pageBackdropARGB`), sampled from the
/// document when it loads and again when a live resize starts, so the gap
/// reads as more page instead of white or the window backdrop.
extension CEFTab {
    /// The document's background read (`PageBackground.backdropScript`): `[r, g, b]` for its own, `"dark"` or
    /// `"light"` for none (Chromium paints its canvas then, so its page base stays white), null when translucent.
    static let pageBackdropScript = PageBackground.backdropScript

    /// `pageBackdropScript` once the page has the color scheme it was just sent (`dark`): the scheme reaches the
    /// renderer on its own channel, so the read first waits (bounded) until the page's media query agrees, then one
    /// animation frame (bounded), so a page that restyles from its own `change` listener has done so.
    static func pageBackdropScript(afterScheme dark: Bool) -> String {
        """
        (async () => {
          const query = matchMedia('(prefers-color-scheme: dark)');
          for (let wait = 0; wait < 30 && query.matches !== \(dark); wait++) await new Promise(done => setTimeout(done, 16));
          await new Promise(done => { requestAnimationFrame(() => done()); setTimeout(done, 100); });
          return \(pageBackdropScript);
        })()
        """
    }

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
    /// is a hole that shows the window backdrop).
    /// A document that has not settled yet takes the loading base, so the gap
    /// matches the page area (`CEFTab+LoadingBackground`).
    /// The same rule as a closing pane's ground (`PageBackground.closingGroundARGB`).
    var pageBackdropColor: CGColor? {
        let loading = loadingBaseARGB
        return PageBackground.closingGroundARGB(realPage: pastFirstRealPage, settled: loading == nil, loading: loading,
                                                document: pageBackdropARGB,
                                                canvas: pageCanvasDark ? PageBackground.chromiumDarkCanvasARGB : PageBackground.engineDefaultARGB)
            .map(PageBackground.cgColor)
    }

    /// The ground the page's pane shows when it closes (CLOSE MOTION 2 case 3): the page's own background, as its host
    /// view fills a resize gap with it, so the page's color stays where the page was instead of the window's; nil (the
    /// chrome's ground) before the first real page, under a see-through cmux page and under a document that has not
    /// painted, each of which shows the pane under it (``showsPaneGround``).
    public var pageGround: CGColor? { showsPaneGround ? nil : pageBackdropColor }

    /// Reads the document's background (after a load, when a live resize
    /// starts, and when the page hears a new color scheme) and applies it to
    /// Chromium's page background and the host view. `keepsColorWithoutAnswer`:
    /// an answer that is no color leaves the color read before.
    func samplePageBackdrop(script: String = CEFTab.pageBackdropScript, keepsColorWithoutAnswer: Bool = false) {
        guard pastFirstRealPage, browserID != nil, !isClosed else { return }
        let document = pageBackdropDocument
        Task { [weak self] in
            guard let value = try? await self?.evaluate(script, world: .page, gesture: .cmux) else { return }
            // A navigation since the read: the next document samples its own.
            guard let self, document == self.pageBackdropDocument, !self.isClosed else { return }
            let argb = Self.backdropARGB(from: value)
            let canvasDark = PageBackground.canvasDark(from: value)
            // A scheme re-read keeps the color read before when the answer is none the script gives (a promise the
            // path did not await); null (a translucent background) is an answer.
            if keepsColorWithoutAnswer, argb == nil, canvasDark == nil, value != .null { return }
            guard argb != self.pageBackdropARGB || (canvasDark ?? false) != self.pageCanvasDark else { return }
            self.pageBackdropARGB = argb
            self.pageCanvasDark = canvasDark ?? false
            self.applyPageBackground()
        }
    }

    /// The page was just sent a new `prefers-color-scheme` (`CEFColorScheme.apply`, a theme or appearance change): a
    /// page that follows it changes its own background, which a closing pane and a resize gap must show (CLOSE GROUND
    /// FIX: it was read only at load end and at a live resize start). A document that has not settled reads its color
    /// when it does; when that read is already in flight it may answer with the color from before the scheme, so one
    /// more read follows it.
    func colorSchemeWasSent(dark: Bool) {
        guard documentSettled else {
            if pageBackdropReading == pageBackdropDocument { pageBackdropReReadOwed = true }
            return
        }
        samplePageBackdrop(script: Self.pageBackdropScript(afterScheme: dark), keepsColorWithoutAnswer: true)
    }

    /// A new document committed: its background is unknown until it loads, so
    /// the loading base applies again (a page without a background of its own
    /// must never show the previous page's color).
    func resetPageBackdrop() {
        pageBackdropDocument += 1
        let settled = documentSettled
        documentSettled = false
        pageCanvasDark = false
        guard pageBackdropARGB != nil || settled else { return }
        pageBackdropARGB = nil
        applyPageBackground()
    }
}
