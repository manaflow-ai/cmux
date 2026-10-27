public import AppKit
import WebKit

/// The color a WebKit page shows between a navigation committing and its
/// document painting, the WebKit half of `CEFTab+LoadingBackground`.
extension WebKitTab {
    /// How long the theme color may stand in for a document WebKit has not
    /// reported finished (`pageDidCommit`).
    static let pageBaseHoldLimit = Duration.milliseconds(400)

    /// WKWebView paints white behind every page by default. macOS has no
    /// public switch, so this uses WebKit's `_setDrawsBackground:` SPI
    /// through KVC ("drawsBackground"), checked first; without it the tab
    /// keeps WebKit's default.
    func setDrawsPageBackground(_ draws: Bool) {
        guard webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) else { return }
        webView.setValue(draws, forKey: "drawsBackground")
        drawsPageBackground = draws
    }

    /// What WebKit paints behind the document: its page background SPI (`_pageExtendedBackgroundColor`,
    /// the color `underPageBackgroundColor` takes by default; this tab clears that one), checked first.
    /// Nil while WebKit draws no background, so the page is see-through, and without the SPI.
    public var pageBackgroundColor: CGColor? {
        guard drawsPageBackground, webView.responds(to: NSSelectorFromString("_pageExtendedBackgroundColor")) else { return nil }
        return (webView.value(forKey: "_pageExtendedBackgroundColor") as? NSColor)?.cgColor
    }

    /// A new document committed: WebKit draws no background behind it for a
    /// moment, so the pane's theme shows instead of white while the page
    /// paints (`BrowserPageTunables.loadingBackground`).
    ///
    /// The hold is bounded in time because WebKit reports no first paint,
    /// where Chromium has one to end it exactly (`CEFFirstPaintBridge`).
    /// Holding all the way to `didFinish` would be wrong the same way it is
    /// wrong there: no background is the canvas under the document for as long
    /// as the hold lasts, so a page with no background of its own would show
    /// the UA's black text over a dark theme color for the whole load. On an
    /// ordinary page `didFinish` ends the hold first.
    func pageDidCommit() {
        guard BrowserPageTunables.loadingBackground.value else { return }
        setDrawsPageBackground(false)
        pageBaseHold.schedule(after: Self.pageBaseHoldLimit) { [weak self] in
            self?.pageDidFinish()
        }
    }

    /// The page painted, finished, failed, stopped or lost its renderer: from
    /// now on WebKit draws its default behind it again (white for pages
    /// without a background).
    ///
    /// Every exit from the hold ends here, including the two where nothing
    /// finishes -- a provisional navigation failing over a document still
    /// loading, and a dead web content process -- which would otherwise leave
    /// the page area with no background for good.
    func pageDidFinish() {
        pageBaseHold.cancel()
        guard !PageBackground.isBlank(webView.url) else { return }
        setDrawsPageBackground(true)
    }
}
