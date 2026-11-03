public import CoreGraphics

/// A page that can keep a hibernated tab's picture over itself until it first paints, so a woken
/// tab goes from its last frame straight to the live page with no blank frame between
/// (plans/cmux-next/tab-lifecycle.md, section 3).
///
/// WebKit tabs conform (`WebKitTab`). Chromium tabs get it from the layer-hosting stand-in
/// (`CEFLayerHosting.showStandIn`, owner PL-cef-layer); until then a woken Chromium page shows the
/// theme color until it paints.
@MainActor public protocol BrowserWakeStandIn: AnyObject {
    /// Covers the page with `picture` until the page's own first contentful paint, or until `cap`
    /// passes on `clock`, whichever comes first (a load that ends with nothing painted, fails, is
    /// stopped, a renderer that ends, or a close also remove it).
    /// - Parameters:
    ///   - picture: The tab's last frame: the placeholder's decoded pixels when it was shown
    ///     (`HibernatedBrowserTab.shownPicture`), else the picture as kept while it hibernated.
    ///   - decoded: `picture` is already drawn into a bitmap: the cover shows it from its first
    ///     frame, with no decode. Otherwise it decodes off the main thread once in a window.
    ///   - cap: The longest the picture may stand in for the page: a page that paints late must
    ///     not look frozen.
    ///   - clock: The clock the cap runs on (tests advance a manual one).
    /// - Returns: False when the page cannot show a stand-in now (nothing covers it).
    @discardableResult
    func showStandIn(_ picture: CGImage, decoded: Bool, cap: Duration, clock: any Clock<Duration>) -> Bool
}
