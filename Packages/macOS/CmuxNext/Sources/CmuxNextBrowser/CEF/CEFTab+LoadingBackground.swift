import AppKit

/// The color a Chromium page shows between a navigation committing and the
/// document painting.
///
/// Chromium repaints the whole page area with the browser's background color
/// (`cmux_browser_set_background_color`) as soon as a new document commits,
/// well before that document's first contentful paint. With Chromium's white
/// default that is a white flash on every navigation, and in a dark theme it
/// is the brightest thing on screen (Leo, 2026-10-20). So a committed document
/// whose own background nothing has shown yet keeps the theme page background;
/// the base becomes the document's own color (white included) once its load
/// settles, which is also when `CEFTab+ResizeBackdrop` samples it.
///
/// A loaded page with no background of its own is still white, the web default
/// both engines keep (`PageBackground`): the theme color only fills the gap
/// before the page paints, never under a page that has painted.
extension CEFTab {
    /// The color Chromium paints the page area with
    /// (`PageBackground.chromiumARGB`).
    var pageBaseARGB: UInt32 {
        PageBackground.chromiumARGB(
            pastFirstRealPage: pastFirstRealPage,
            documentSettled: documentSettled || !BrowserPageTunables.loadingBackground.value,
            document: BrowserResizeTunables.pageBackdrop.value ? pageBackdropARGB : nil,
            newTab: PageBackground.themeARGB(in: container, surface: .newTabPage),
            loading: PageBackground.themeARGB(in: container))
    }

    /// The theme base of a committed document that has not settled yet; nil
    /// once it has, or with `BrowserPageTunables.loadingBackground` off.
    var loadingBaseARGB: UInt32? {
        guard BrowserPageTunables.loadingBackground.value, pastFirstRealPage, !documentSettled else { return nil }
        return PageBackground.themeARGB(in: container)
    }

    /// The committed document finished loading, failed with a page Chromium
    /// draws, or its load ended: it owns the page area from now on, so the
    /// base stops standing in for it.
    func documentDidSettle() {
        guard pastFirstRealPage, !documentSettled else { return }
        documentSettled = true
        applyPageBackground()
    }
}
