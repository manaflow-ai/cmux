import AppKit
import CmuxNextDesign

/// The page area of a tab shows the Ghostty theme background
/// (`Palette.pageBackground`) only before its first real page (a new tab,
/// loading); after it, a page without a background of its own is white
/// (the web default), popups and moved tabs included (coordinator
/// decision 2026-09-30, both engines). Chromium starts on
/// `CefBrowserSettings.background_color` and switches per tab with
/// `cmux_browser_set_background_color` (fork API 12, which also paints it
/// in Chromium's contents view, so it survives tab moves and popups).
/// A tab on the New Tab or blank page is transparent in both engines
/// (Lawrence 2026-10-10): WebKit draws no background there, and Chromium's
/// page, which cannot be transparent, is masked out (`CEFTab.applyOcclusion`),
/// so the window's backdrop shows.
nonisolated enum PageBackground {
    /// A URL whose document keeps the theme color in WebKit: nothing, or
    /// the page of a new tab.
    static func isBlank(_ url: URL?) -> Bool {
        guard let url else { return true }
        return url.absoluteString.isEmpty || BrowserNewTabPage.isNewTabPage(url)
    }

    /// WebKit: whether a new page starts on the theme color: only a tab
    /// cmux opens (a new tab, before its first paint). A page a page opened
    /// (a popup, target=_blank) takes WebKit's default at once. Chromium
    /// does the same (`CEFTab.pastFirstRealPage`).
    static func startsWithTheme(openedByPage: Bool) -> Bool { !openedByPage }

    /// Chromium's white default, 0xAARRGGBB.
    static let engineDefaultARGB: UInt32 = 0xFFFF_FFFF

    /// The canvas Chromium paints under a document with no background of its own whose color scheme is dark (Blink's
    /// dark base background, rgb(18, 18, 18), over a white page base); `backdropScript` answers `"dark"` for it.
    static let chromiumDarkCanvasARGB: UInt32 = 0xFF12_1212
    /// WebKit's canvas for the same document (the dark system control background, rgb(30, 30, 30)).
    static let webKitDarkCanvasARGB: UInt32 = 0xFF1E_1E1E

    /// A script expression, true when the document's canvas is dark: the root's used color scheme (its `color-scheme`,
    /// else the `color-scheme` meta) allows dark, and either allows no light or the page prefers dark. Both engines' page
    /// background reads use it for a document with no background of its own.
    static let usesDarkCanvasScript = """
    (() => {
      let scheme = getComputedStyle(document.documentElement).colorScheme || 'normal';
      if (scheme === 'normal') scheme = document.querySelector('meta[name="color-scheme" i]')?.content || 'normal';
      const words = scheme.toLowerCase().replaceAll(',', ' ').split(' ');
      if (!words.includes('dark')) return false;
      return !words.includes('light') || matchMedia('(prefers-color-scheme: dark)').matches;
    })()
    """

    /// The document's background, one read for both engines (Chromium in the page's world, WebKit in an isolated one):
    /// `[r, g, b]` (0-255) for the root element's, else the body's (CSS propagates it to the canvas); `"dark"` or
    /// `"light"` when neither has one, the canvas the engine paints for the document's color scheme
    /// (`usesDarkCanvasScript`); null when the first one set is translucent (the engine's base stays, since the page
    /// paints its color over that base). A 1x1 canvas turns any CSS color syntax into sRGB bytes.
    static let backdropScript = """
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
        // Translucent: the page paints it over the engine's base, so a base of the same color would darken it.
        return a === 255 ? [r, g, b] : null;
      }
      return \(usesDarkCanvasScript) ? 'dark' : 'light';
    })()
    """

    /// `backdropScript`'s answer for a document with no background of its own: true for `"dark"`, false for `"light"`;
    /// nil for any other answer.
    static func canvasDark(from value: BrowserJSValue) -> Bool? {
        guard case .string(let canvas) = value else { return nil }
        return canvas == "dark" ? true : canvas == "light" ? false : nil
    }

    /// The ground a closing page pane shows (CLOSE GROUND FIX, review of #37344): the color its page area paints, one
    /// rule for both engines. Nil (the chrome's own ground) when the tab shows no real page; while a committed document
    /// has not settled, the engine's loading base (nil where the engine paints none, WebKit's hold, so the chrome's
    /// ground shows as it does in the page area); then the document's own background, else the engine's canvas
    /// (`canvas`: white, or dark under a dark color scheme), never the window's color.
    static func closingGroundARGB(realPage: Bool, settled: Bool, loading: UInt32?, document: UInt32?,
                                  canvas: UInt32) -> UInt32? {
        guard realPage else { return nil }
        guard settled else { return loading }
        return document ?? canvas
    }

    /// Opaque 0xAARRGGBB as an sRGB color.
    static func cgColor(_ argb: UInt32) -> CGColor {
        func channel(_ shift: UInt32) -> CGFloat { CGFloat((argb >> shift) & 0xFF) / 255 }
        return CGColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
    }

    /// The Chromium page background, in the order the page's own paint takes
    /// it over: the theme color until the tab's first real page, the theme
    /// color again while a committed document has not painted
    /// (`CEFTab+LoadingBackground`), then the document's own background, then
    /// Chromium's white.
    ///
    /// - Parameters:
    ///   - pastFirstRealPage: The tab showed a real page (`CEFTab.pastFirstRealPage`).
    ///   - documentSettled: The committed document's load ended, so it owns the page area.
    ///   - document: The document's own background once read (`CEFTab+ResizeBackdrop`); nil for white.
    ///   - newTab: The theme color of the New Tab surface.
    ///   - loading: The theme color behind a committed page that has not painted.
    static func chromiumARGB(pastFirstRealPage: Bool, documentSettled: Bool, document: UInt32?,
                             newTab: UInt32, loading: UInt32) -> UInt32 {
        guard pastFirstRealPage else { return newTab }
        guard documentSettled else { return loading }
        return document ?? engineDefaultARGB
    }

    /// True when a committed document is a real page (not blank, not the
    /// New Tab page).
    static func isRealPage(_ url: URL?) -> Bool { !isBlank(url) }

    /// `Palette.pageBackground` of `view`'s theme scope (its room,
    /// workspace or terminal theme) as opaque 0xAARRGGBB, the form
    /// `CefBrowserSettings.background_color` takes.
    @MainActor static func themeARGB(in view: NSView, surface: SurfaceKind? = nil) -> UInt32 {
        argb(view.performWithTheme {
            if let surface, let override = Palette.surfaceOverride(surface) { return override.withAlphaComponent(1) }
            return Palette.pageBackground
        })
    }

    /// The app theme's (Ghostty config) page background: Chromium's
    /// process default for a browser before it joins a scoped view.
    @MainActor static var appThemeARGB: UInt32 {
        argb(ThemeScope.app.perform { Palette.pageBackground })
    }

    static func argb(_ color: NSColor) -> UInt32 {
        let color = color.usingColorSpace(.sRGB) ?? .black
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return 0xFF00_0000 | byte(color.redComponent) << 16 | byte(color.greenComponent) << 8 | byte(color.blueComponent)
    }
}
