import AppKit
import CmuxNextDesign

/// The color a Chromium page shows between a navigation committing and the
/// document painting.
///
/// Chromium repaints the whole page area with the browser's background color
/// (`cmux_browser_set_background_color`) as soon as a new document commits,
/// well before that document's first contentful paint. With Chromium's white
/// default that is a white flash on every navigation, and in a dark theme it
/// is the brightest thing on screen (Leo, 2026-10-20). So a committed document
/// that has not painted yet keeps the theme page background; the base becomes
/// the document's own color (white included) as soon as it paints.
///
/// "Has not painted" is Blink's first contentful paint
/// (`CEFFirstPaintBridge`), not the end of the load: the base is Chromium's
/// canvas fill for the document's whole lifetime, so holding it to load end
/// would put the theme color under a page already being read -- on a page with
/// no background of its own, the UA's black text over a dark theme color, and
/// then the white flash anyway at load end. A load that ends with nothing
/// painted (an empty body, a download) settles then, as the backstop.
///
/// A painted page with no background of its own is still white, the web
/// default both engines keep (`PageBackground`).
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

    /// The committed document painted content (`CEFFirstPaintBridge`), or its
    /// load ended with nothing painted: it owns the page area from now on, so
    /// the base stops standing in for it.
    func documentDidSettle() {
        guard pastFirstRealPage, !documentSettled else { return }
        documentSettled = true
        applyPageBackground()
    }

    /// A real page committed, or a page opened this tab (a popup,
    /// target=_blank): Chromium's white default from now on, kept across tab
    /// moves and popups (fork API 12).
    ///
    /// - Parameter settled: the tab already holds a painted document, so no
    ///   event of ours will settle it. A tab adopted after Chromium created
    ///   and loaded it (a popup, a `target=_blank` window) has no
    ///   `OnLoadStart`/`OnLoadEnd` of its own.
    func reachedFirstRealPage(settled: Bool = false) {
        guard !pastFirstRealPage else { return }
        pastFirstRealPage = true
        if settled { documentSettled = true }
        applyPageBackground()
        applyOcclusion()
    }

    /// The tab's view moved or its theme scope changed: a page still on
    /// the theme color takes the new scope's color, and a page that follows
    /// the app hears the new appearance.
    func pageThemeDidChange() {
        if colorScheme == .system { reapplyColorScheme() }
        guard !pastFirstRealPage || pageThemeSurface != nil || !documentSettled else { return }
        applyPageBackground()
    }

    /// Every attached tab owns its background (theme color of its own scope
    /// until the first real page, then the theme color again until the
    /// committed document paints, then the document's own background once
    /// read, else white), so a theme change of another room or workspace never
    /// repaints it.
    func applyPageBackground() {
        applyHostBackdrop()
        guard let browser = browserID, let shim = runtime.shim else { return }
        // The color stays the page's color whenever it is not see-through (and on a fork without API 17).
        if let pageThemeSurface {
            _ = shim.browserSetBackgroundColor(browser, PageBackground.themeARGB(in: container, surface: pageThemeSurface))
        } else {
            _ = shim.browserSetBackgroundColor(browser, pageBaseARGB)
        }
        if pageSeeThrough { _ = shim.tabSetTransparentBackground(browser, 1) }
    }

    /// The shared host view under the page window takes this tab's page
    /// color while it shows this tab.
    func applyHostBackdrop() {
        guard host.visibleTab === self else { return }
        host.hostView.pageSeeThrough = pageSeeThrough
        host.hostView.pageBackdrop = pageBackdropColor
    }
}
